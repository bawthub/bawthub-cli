#!/usr/bin/env python3
"""Reconcile only houses; dry-run unless --apply is explicit."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, build_opener

from house_reconcile import House, apply, desired_ids, plan
from house_reconcile_edge import DNS, NoRedirect

SERVICE = re.compile(r"house-(h[1-9][0-9]*)\Z")


def run(command, payload=None, env=None):
    try:
        result = subprocess.run(
            command,
            env=env,
            input=None if payload is None else json.dumps(payload),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=180,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise RuntimeError("house command unavailable or timed out") from None
    if result.returncode:
        # Compose/env-file and transport errors can contain credentials.
        raise RuntimeError("house command failed; output withheld to protect secrets")
    return result.stdout


def definition_hashes(command, houses):
    """Match ``up`` hashes, resolving env files only in subprocess memory.

    Compose's direct ``config --hash`` skips service environment resolution.
    Reparse its fully resolved JSON via stdin instead; never persist or log it.
    """
    services = {f"house-{house}" for house in houses}
    if not services:
        return {}
    model = json.loads(run(command + ["config", "--format", "json"]))
    stdin_command = []
    skip = False
    for arg in command:
        if skip:
            skip = False
        elif arg in {"-f", "--file"}:
            skip = True
        elif not arg.startswith("--file="):
            stdin_command.append(arg)
    output = run(
        stdin_command + ["-f", "-", "config", "--hash", ",".join(sorted(services))],
        model,
    )
    hashes = {}
    for line in output.splitlines():
        parts = line.split()
        if (
            len(parts) != 2
            or parts[0] not in services
            or parts[0] in hashes
            or not re.fullmatch("[a-f0-9]{64}", parts[1])
        ):
            raise ValueError(
                "Compose did not return the expected house definition hash"
            )
        hashes[parts[0]] = parts[1]
    if hashes.keys() != services:
        raise ValueError("Compose did not return all expected house definition hashes")
    return hashes


def write_changed(path, content, *, preserve_inode=False):
    path = Path(path)
    data = content if isinstance(content, str) else json.dumps(content, indent=2) + "\n"
    if path.exists() and path.read_text() == data:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    if preserve_inode and path.exists():
        # A file bind observes this inode, not a replacement at the same path.
        with path.open("r+") as handle:
            handle.write(data)
            handle.truncate()
            handle.flush()
            os.fsync(handle.fileno())
    else:
        fd, temporary = tempfile.mkstemp(prefix=".houses-", dir=path.parent)
        try:
            with os.fdopen(fd, "w") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o644)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    return True


def inventory(project):
    rows = run(
        [
            "docker",
            "ps",
            "-a",
            "--filter",
            f"label=com.docker.compose.project={project}",
            "--format",
            '{{.ID}} {{.Label "com.docker.compose.service"}}',
        ]
    ).splitlines()
    houses = []
    template = (
        '{"id":{{json .Id}},"project":{{json (index .Config.Labels "com.docker.compose.project")}},'
        '"service":{{json (index .Config.Labels "com.docker.compose.service")}},'
        '"hash":{{json (index .Config.Labels "com.docker.compose.config-hash")}},'
        '"running":{{json .State.Running}},"health":'
        '{{if .State.Health}}{{json .State.Health.Status}}{{else}}"missing"{{end}}}'
    )
    for line in rows:
        parts = line.split()
        if len(parts) != 2 or not SERVICE.fullmatch(parts[1]):
            continue
        row = json.loads(run(["docker", "inspect", "--format", template, parts[0]]))
        houses.append(
            House(
                SERVICE.fullmatch(parts[1])[1],
                row["id"],
                row["project"],
                row["service"],
                row["hash"],
                row["running"],
                row["health"] == "healthy",
            )
        )
    return houses


class Host:
    def __init__(self, settings, count, scratch):
        self.settings = settings
        self.count = count
        self.project = settings["project"]
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", self.project):
            raise ValueError("invalid Compose project")
        self.command = settings["compose_command"]
        if not isinstance(self.command, list) or not all(
            isinstance(s, str) for s in self.command
        ):
            raise ValueError("compose_command must be an argument array")
        if not any(
            self.command[i : i + 2] == [flag, self.project]
            for flag in ("-p", "--project-name")
            for i in range(len(self.command) - 1)
        ):
            raise ValueError("compose_command requires the exact project name")
        published = settings["compose_file"]
        if self.command.count(published) != 1:
            raise ValueError(
                "compose_command must include its published house overlay once"
            )
        if settings.get("layout", "rendered") == "rendered":
            candidate = settings["desired_compose_file"]
            self.pool = json.loads(Path(settings["desired_pool_file"]).read_text())
            self.overlay = Path(candidate).read_text()
            self.routes = None
        elif settings["layout"] == "extends":
            rendering = settings["renderer"]
            bundle = json.loads(
                run(
                    self.command
                    + [
                        "exec",
                        "-T",
                        settings.get("app_service", "app"),
                        "python",
                        "-m",
                        "agent_bridge.house_pool",
                        "bundle",
                        "-",
                    ],
                    {
                        "count": count,
                        "pool": rendering["pool"],
                        "origin_template": rendering["origin_template"],
                        "base_compose": rendering["base_compose"],
                        "route_template": Path(
                            rendering["route_template_file"]
                        ).read_text(),
                    },
                )
            )
            self.pool, self.routes = bundle["pool"], bundle["routes"]
            self.overlay = json.dumps(bundle["compose"], indent=2) + "\n"
            candidate = str(scratch)
            Path(candidate).write_text(self.overlay)
        else:
            raise ValueError("unknown house rendering layout")
        self.candidate_command = [
            candidate if arg == published else arg for arg in self.command
        ]
        self.houses = self.pool["houses"]
        if [row["id"] for row in self.houses] != desired_ids(count):
            raise ValueError("rendered pool differs from HOUSES")
        self.origins = {row["id"]: row["origin"] for row in self.houses}
        for origin in self.origins.values():
            parsed = urlsplit(origin)
            if (
                parsed.scheme not in {"http", "https"}
                or not parsed.hostname
                or parsed.username
                or parsed.password
                or parsed.path not in {"", "/"}
                or parsed.query
                or parsed.fragment
            ):
                raise ValueError("invalid rendered preview origin")
        self.journal_path = Path(settings["journal_file"])
        self.journal = (
            json.loads(self.journal_path.read_text())
            if self.journal_path.exists()
            else {}
        )
        if self.journal and self.journal.get("project") != self.project:
            raise ValueError("journal belongs to another Compose project")
        if (
            self.journal.get("status") == "running"
            and self.journal.get("count") != count
        ):
            raise ValueError("resume unfinished reconciliation before changing HOUSES")
        digest = hashlib.sha256(
            json.dumps(
                [self.pool, self.overlay, self.routes],
                sort_keys=True,
            ).encode()
        ).hexdigest()
        if (
            self.journal.get("status") == "running"
            and self.journal.get("desired_digest") != digest
        ):
            raise ValueError(
                "unfinished reconciliation requires its original rendered definitions"
            )
        self.run_id = (
            self.journal.get("run_id")
            if self.journal.get("status") == "running"
            else uuid.uuid4().hex
        )
        self.journal.update(
            project=self.project, count=count, run_id=self.run_id, desired_digest=digest
        )
        self.dns = DNS(
            settings.get("edge", {}),
            self.journal.setdefault("dns_owned", {}),
            self.save,
        )
        self.initial = inventory(self.project)

    def save(self):
        write_changed(self.journal_path, self.journal)

    def runtime(self, action, houses):
        result = json.loads(
            run(
                self.candidate_command
                + [
                    "exec",
                    "-T",
                    self.settings.get("app_service", "app"),
                    "python",
                    "-m",
                    "llm_bawt.house_reconcile_runtime",
                ],
                {"action": action, "houses": houses, "reconcile_id": self.run_id},
            )
        )
        if "error" in result:
            raise ValueError("app refused house reconciliation")
        return result

    def preview(self):
        hashes = definition_hashes(self.candidate_command, desired_ids(self.count))
        # A never-installed tenant can plan additions without starting its app.
        if not self.initial and not Path(self.settings["pool_file"]).exists():
            runtime = {"houses": []}
        else:
            runtime = self.runtime("inspect", [])
            seen = {row["house"] for row in runtime["houses"]}
            missing = sorted({row.house for row in self.initial} - seen)
            if missing:
                runtime["houses"].extend(self.runtime("inspect", missing)["houses"])
        changes = plan(
            self.count, self.project, self.initial, hashes, runtime, run_id=self.run_id
        )
        self.hashes = hashes
        edge = self.dns.plan(
            [urlsplit(origin).hostname for origin in self.origins.values()]
        )
        return changes, edge

    def reserve(self, houses):
        self.runtime("reserve", houses)
        # Keep holds this run already owns (a resume reserves fewer houses).
        held = self.journal.get("reserved", [])
        self.journal["reserved"] = held + [h for h in houses if h not in held]
        self.save()

    def remove(self, house):
        current = {row.house: row for row in inventory(self.project)}.get(house)
        initial = {row.house: row for row in self.initial}.get(house)
        if current is None:
            return
        if initial is None or current.container_id != initial.container_id:
            raise ValueError(f"{house} container identity changed since planning")
        state = self.runtime("inspect", [house])["houses"]
        if (
            len(state) != 1
            or state[0]["reasons"]
            or state[0]["reservation"] != self.run_id
        ):
            raise ValueError(f"{house} removal reservation is not exclusive")
        run(["docker", "stop", "--time", "30", current.container_id])
        run(["docker", "rm", current.container_id])  # never remove volumes
        self.journal.setdefault("removed", []).append(house)
        self.save()

    def frozen_inputs(self, service, container_id):
        """Interpolation values that re-render the running container's definition.

        The tenant manifest may already name the new image, so the published
        overlay alone would render the new definition. Each variable the
        service references is recovered from the running container (its image
        or the environment entry that is exactly that variable). Values stay in
        subprocess memory; the config hash check after rollback proves them.
        """
        model = json.loads(
            run(self.command + ["config", "--no-interpolate", "--format", "json"])
        )
        definition = model.get("services", {}).get(service)
        if not isinstance(definition, dict):
            raise ValueError(f"{service} is missing from the published definition")
        old = json.loads(
            run(
                [
                    "docker",
                    "inspect",
                    "--format",
                    '{"image":{{json .Config.Image}},"env":{{json .Config.Env}}}',
                    container_id,
                ]
            )
        )
        env = dict(item.split("=", 1) for item in old["env"] or [] if "=" in item)
        whole = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?:[:?+-][^}]*)?\}\Z")
        pairs = []
        if isinstance(definition.get("image"), str):
            pairs.append((definition["image"], old["image"]))
        environment = definition.get("environment") or {}
        if isinstance(environment, list):
            # Uninterpolated config keeps the list form: "KEY=VALUE" entries.
            environment = dict(
                item.split("=", 1)
                for item in environment
                if isinstance(item, str) and "=" in item
            )
        for key, value in environment.items():
            if isinstance(value, str) and key in env:
                pairs.append((value, env[key]))
        frozen = {}
        for expression, value in pairs:
            match = whole.match(expression)
            if match is None:
                continue
            if frozen.setdefault(match[1], value) != value:
                raise ValueError(f"{service} previous definition is inconsistent")
        text = json.dumps(definition).replace("$$", "")
        referenced = set(re.findall(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)", text))
        if referenced - frozen.keys():
            raise ValueError(
                f"{service} previous definition cannot be frozen; replacement refused"
            )
        return frozen

    def replace(self, house):
        """Recreate a reserved, free house on the candidate definition or roll back.

        ``apply`` holds this run's reservation, which blocks new assignment, so
        no command can be routed to the old container. Rollback re-renders the
        published overlay with the old container's own interpolation values and
        must reach the old config hash exactly.
        """
        current = {row.house: row for row in inventory(self.project)}.get(house)
        initial = {row.house: row for row in self.initial}.get(house)
        if current is None or initial is None:
            raise ValueError(f"{house} disappeared since planning")
        if current.container_id != initial.container_id:
            raise ValueError(f"{house} container identity changed since planning")
        state = self.runtime("inspect", [house])["houses"]
        if (
            len(state) != 1
            or state[0]["reasons"]
            or state[0]["reservation"] != self.run_id
        ):
            raise ValueError(f"{house} replacement reservation is not exclusive")
        service = f"house-{house}"
        frozen = self.frozen_inputs(service, current.container_id)
        self.journal.setdefault("replacing", {})[house] = initial.config_hash
        self.save()
        # Graceful stop first so an in-flight command is not killed mid-write.
        run(["docker", "stop", "--time", "30", current.container_id])
        try:
            run(
                self.candidate_command
                + ["up", "-d", "--no-deps", "--no-build", "--force-recreate", service]
            )
            self.wait_healthy(house, self.hashes[service])
        except (ValueError, RuntimeError):
            run(
                self.command
                + [
                    "up",
                    "-d",
                    "--no-deps",
                    "--no-build",
                    "--pull",
                    "never",
                    "--force-recreate",
                    service,
                ],
                env={**os.environ, **frozen},
            )
            self.wait_healthy(house, initial.config_hash)
            self.journal["replacing"].pop(house)
            self.journal.setdefault("rolled_back", []).append(house)
            self.save()
            # Nothing is published yet and the house is back on its previous
            # definition, so end this run cleanly: lift its holds once the
            # houses are live again and let a corrected manifest rerun fresh.
            self.cancel(list(self.journal.get("reserved", [])))
            self.journal["status"] = "rolled_back"
            self.save()
            raise ValueError(
                f"{house} replacement failed its health check; rolled back"
            ) from None
        self.journal["replacing"].pop(house)
        self.journal.setdefault("replaced", []).append(house)
        self.save()

    def wait_healthy(self, house, expected):
        deadline = time.monotonic() + self.verify_timeout()
        while True:
            current = next(
                (row for row in inventory(self.project) if row.house == house), None
            )
            if (
                current is not None
                and current.config_hash == expected
                and current.running
                and current.healthy
            ):
                return
            if time.monotonic() >= deadline:
                raise ValueError(f"{house} did not become healthy")
            time.sleep(2)

    def verify_timeout(self):
        timeout = self.settings.get("verify_timeout", 180)
        if type(timeout) is not int or not 1 <= timeout <= 3600:
            raise ValueError("verify_timeout must be 1..3600 seconds")
        return timeout

    def publish(self):
        write_changed(self.settings["compose_file"], self.overlay)
        if self.routes is not None:
            write_changed(self.settings["routes_file"], self.routes)
        write_changed(self.settings["pool_file"], self.pool, preserve_inode=True)
        self.journal["published"] = True
        self.save()

    def start(self, house):
        # Existing houses are NEVER recreated, even if another writer appeared
        # after planning. Definition/identity checks in verify still must pass.
        run(
            self.command
            + ["up", "-d", "--no-deps", "--no-build", "--no-recreate", f"house-{house}"]
        )
        self.journal.setdefault("started", []).append(house)
        self.save()

    def edge(self, houses):
        self.dns.ensure([urlsplit(self.origins[house]).hostname for house in houses])

    def release(self, houses):
        self.runtime("release", houses)
        self.journal["reserved"] = [
            house for house in self.journal.get("reserved", []) if house not in houses
        ]
        self.save()

    def cancel(self, houses):
        """Lift a replaced (retained) house's hold once its new lease is live.

        The runtime only cancels a configured house with a live lease; wait for
        the replacement bridge to take it rather than failing on a race.
        """
        if not houses:
            return
        deadline = time.monotonic() + self.verify_timeout()
        # A house leaving the pool is only in the still-published pool.
        published = Path(self.settings.get("pool_file") or "")
        old = json.loads(published.read_text())["houses"] if published.is_file() else []
        harnesses = {row["id"]: row["harness"] for row in [*old, *self.houses]}
        if any(house not in harnesses for house in houses):
            raise ValueError("held house is in neither pool; hold kept")
        while True:
            rows = self.runtime("inspect", houses)["houses"]
            if len(rows) == len(houses) and all(
                row["configured"] and harnesses[row["house"]] in row["live"]
                for row in rows
            ):
                break
            if time.monotonic() >= deadline:
                raise ValueError("replaced house has no live lease; hold kept")
            time.sleep(2)
        self.runtime("cancel", houses)
        self.journal["reserved"] = [
            house for house in self.journal.get("reserved", []) if house not in houses
        ]
        self.save()

    def verify(self, house):
        progress = os.environ.get("BAWTHUB_HOUSE_INSTALL_PROGRESS") == "1"
        next_report = time.monotonic()
        deadline = next_report + self.verify_timeout()
        harness = next(row["harness"] for row in self.houses if row["id"] == house)
        while True:
            now = time.monotonic()
            if progress and now >= next_report:
                print(
                    f"bootstrap: @step Waiting for workspace {house} (health and agent connection)",
                    flush=True,
                )
                next_report = now + 20
            current = next(
                (row for row in inventory(self.project) if row.house == house), None
            )
            if (
                current is not None
                and current.config_hash != self.hashes[f"house-{house}"]
            ):
                raise ValueError(f"{house} definition changed after planning")
            if current is not None and current.running and current.healthy:
                rows = self.runtime("inspect", [house])["houses"]
                if (
                    len(rows) == 1
                    and rows[0]["configured"]
                    and harness in rows[0]["live"]
                    and rows[0]["reservation"] is None
                    and rows[0].get("preview_host") == self.origins[house]
                ):
                    # Previews off (a small tenant host): nothing serves the
                    # preview port, so health and lease are the whole check.
                    if not self.settings.get("preview_probe", True):
                        return
                    try:
                        opener = build_opener(NoRedirect())
                        with opener.open(
                            Request(self.origins[house], method="GET"), timeout=10
                        ) as response:
                            code = response.status
                    except HTTPError as exc:
                        code = exc.code
                    except OSError:
                        code = 0
                    if code in {200, 301, 302, 303, 307, 308, 401}:
                        return
            if time.monotonic() >= deadline:
                raise ValueError(
                    f"{house} health, lease or preview reachability check failed"
                )
            time.sleep(2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--settings", required=True, type=Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    try:
        raw_count = os.environ.get("HOUSES", "2")
        if not re.fullmatch(r"[0-9]{1,2}", raw_count):
            raise ValueError("HOUSES must be 0..16")
        count = int(raw_count)
        desired_ids(count)
        settings = json.loads(args.settings.read_text())
        project = settings["project"]
        if not isinstance(project, str) or not re.fullmatch(
            r"[a-z0-9][a-z0-9_-]*", project
        ):
            raise ValueError("invalid Compose project")
        # All reconciliations of this host/project share one lock, including
        # different layout adapters. A dry-run creates no tenant state files.
        lock_path = (
            Path(tempfile.gettempdir()) / f"bawthub-houses-{os.getuid()}-{project}.lock"
        )
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with (
            os.fdopen(fd, "r+"),
            # The secrets wrapper mounts the overlay's directory read-only.
            # Keep scratch beside it so existing sibling env_files stay visible.
            tempfile.NamedTemporaryFile(
                prefix=".house-plan-",
                suffix=".compose.json",
                dir=Path(settings["compose_file"]).parent,
            ) as temporary,
        ):
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            host = Host(settings, count, Path(temporary.name))
            changes, edge = host.preview()
            manual = []
            if count and not settings.get("edge", {}).get("proxy_policy_receipt"):
                manual.append(
                    "Confirm preview ingress TLS, authentication and network-access policy."
                )
            result = {
                "mode": "apply" if args.apply else "dry-run",
                "project": project,
                "count": count,
                "reconcile_id": host.run_id,
                "changes": [vars(change) for change in changes],
                "dns": edge,
                "manual_checks": manual,
            }
            if args.apply:
                if any(change.action == "refuse" for change in changes):
                    raise ValueError(
                        "reconciliation refused; run the read-only plan for details"
                    )
                # A never-installed dry-run is allowed without an app; apply
                # always requires an available configured runtime.
                host.runtime("inspect", [])
                host.journal["status"] = "running"
                host.save()
                result.update(apply(changes, host))
                host.dns.remove_owned(
                    {urlsplit(origin).hostname for origin in host.origins.values()}
                )
                host.journal["status"] = "complete"
                host.save()
            print(json.dumps(result, indent=2))
        return 0
    except (ValueError, RuntimeError) as exc:
        print(
            json.dumps(
                {"error": str(exc), "partial_work": "Check the reconciliation journal."}
            )
        )
        return 1
    except Exception as exc:
        print(
            json.dumps(
                {
                    "error": type(exc).__name__,
                    "partial_work": "Check the reconciliation journal.",
                }
            )
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
