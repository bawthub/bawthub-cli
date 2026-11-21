"""Shared, house-only count reconciliation; no tenant database credentials.

Rendering is deployment-specific. This module owns the single inventory,
adoption, add/remove and verification algorithm used by both layouts.
"""

from __future__ import annotations

import re
from dataclasses import asdict, dataclass
from typing import Any, Protocol

_SERVICE = re.compile(r"house-(h[1-9][0-9]*)\Z")
RESUME_HOLD = "resume_own_hold"


@dataclass(frozen=True)
class House:
    house: str
    container_id: str
    project: str
    service: str
    config_hash: str
    running: bool
    healthy: bool


@dataclass(frozen=True)
class Change:
    house: str
    action: str
    reason: str = ""


def desired_ids(count: int) -> list[str]:
    if type(count) is not int or not 0 <= count <= 16:
        raise ValueError("HOUSES must be an integer from 0 to 16")
    return [f"h{i}" for i in range(1, count + 1)]


def plan(
    count: int,
    project: str,
    inventory: list[House],
    config_hashes: dict[str, str],
    runtime: dict[str, Any],
    run_id: str | None = None,
) -> list[Change]:
    desired = desired_ids(count)
    if not isinstance(project, str) or not project:
        raise ValueError("an exact Compose project is required")
    current: dict[str, House] = {}
    for house in inventory:
        match = _SERVICE.fullmatch(house.service)
        if house.project != project or not match:
            continue
        if match[1] != house.house or house.house in current:
            raise ValueError("ambiguous managed house identity")
        current[house.house] = house
    states = {}
    for row in runtime.get("houses", []):
        if (
            not isinstance(row, dict)
            or not isinstance(row.get("house"), str)
            or not _SERVICE.fullmatch(f"house-{row['house']}")
            or row["house"] in states
            or not isinstance(row.get("reasons"), list)
            or any(not isinstance(reason, str) for reason in row["reasons"])
            or type(row.get("configured")) is not bool
            or not isinstance(row.get("live"), list)
            or "reservation" not in row
        ):
            raise ValueError("unrecognized runtime occupancy")
        states[row["house"]] = row
    changes = []
    for house in desired:
        reservation = states.get(house, {}).get("reservation")
        # This run's own hold (a resumed run that failed before finishing a
        # replacement) is resumable; anything else is an unfinished removal.
        if reservation is not None and (run_id is None or reservation != run_id):
            changes.append(
                Change(house, "refuse", "house has an unfinished removal reservation")
            )
            continue
        expected = config_hashes.get(f"house-{house}")
        if not expected:
            raise ValueError(f"renderer omitted definition hash for {house}")
        existing = current.get(house)
        if existing is None:
            changes.append(Change(house, "create"))
        elif not existing.config_hash or existing.config_hash != expected:
            # Only a fully free house is replaced: apply reserves it, which
            # blocks new assignment, so no command can be routed to the old
            # container's epoch. A tenant must be moved out first.
            row = states.get(house)
            if row is None:
                changes.append(Change(house, "refuse", "runtime occupancy unavailable"))
            elif "assigned" in row["reasons"]:
                changes.append(
                    Change(
                        house,
                        "refuse",
                        "changed house has a tenant; move it out, then rerun",
                    )
                )
            elif row["reasons"]:
                changes.append(
                    Change(house, "refuse", "changed house is busy or reserved")
                )
            else:
                changes.append(Change(house, "replace"))
        elif not existing.running:
            changes.append(Change(house, "start"))
        elif not existing.healthy:
            changes.append(Change(house, "refuse", "existing house is unhealthy"))
        else:
            changes.append(Change(house, "adopt"))
        if reservation is not None and changes[-1].action in {
            "adopt",
            "start",
            "create",
        }:
            # Already upgraded by this run before it stopped: its hold must
            # still be lifted, or the house stays unassignable.
            changes[-1] = Change(house, changes[-1].action, RESUME_HOLD)
    # A crash can remove a container before publishing its smaller pool.
    # Include configured/reserved rows so retries finish that removal rather
    # than leaving an advertised ghost and permanent retirement reservation.
    known = set(current) | {
        house
        for house, row in states.items()
        if row["configured"] or row["reservation"] is not None
    }
    for house in sorted(known - set(desired)):
        row = states.get(house)
        if row is None:
            changes.append(Change(house, "refuse", "runtime occupancy unavailable"))
        elif row.get("reasons"):
            changes.append(
                Change(house, "refuse", "runtime reports occupied or reserved")
            )
        else:
            changes.append(Change(house, "remove"))
    return changes


class Backend(Protocol):
    """The host adapter has Docker/edge access, never direct PG/Redis access."""

    def reserve(self, houses: list[str]) -> None: ...
    def publish(self) -> None: ...
    def start(self, house: str) -> None: ...
    def remove(self, house: str) -> None: ...
    def replace(self, house: str) -> None: ...
    def verify(self, house: str) -> None: ...
    def release(self, houses: list[str]) -> None: ...
    def cancel(self, houses: list[str]) -> None: ...
    def edge(self, houses: list[str]) -> None: ...


def apply(changes: list[Change], backend: Backend) -> dict[str, Any]:
    """Reservations survive any failure; the adapter journals completed work."""
    if (
        len({change.house for change in changes}) != len(changes)
        or any(not _SERVICE.fullmatch(f"house-{change.house}") for change in changes)
        or any(
            change.action
            not in {"adopt", "create", "start", "replace", "remove", "refuse"}
            for change in changes
        )
    ):
        raise ValueError("invalid reconciliation plan")
    if any(change.action == "refuse" for change in changes):
        raise ValueError("reconciliation refused; inspect the read-only plan")
    removed = [change.house for change in changes if change.action == "remove"]
    replaced = [change.house for change in changes if change.action == "replace"]
    retained = [change.house for change in changes if change.action != "remove"]
    if removed or replaced:
        # Authoritative recheck, not the earlier plan; the reservation also
        # blocks new assignment until the replacement is healthy.
        backend.reserve(removed + replaced)
    # Resolve edge prerequisites before creating containers. Existing matching
    # resources are adopted; errors keep any reservations in place.
    backend.edge(retained)
    # Replace on the candidate definition before publishing it, so a failed
    # replacement rolls back to the frozen previous definition.
    for house in replaced:
        backend.replace(house)
    if replaced:
        backend.cancel(replaced)  # retained houses: cancel, never removal release
    for change in changes:
        if change.action == "remove":
            backend.remove(change.house)
    backend.publish()
    for change in changes:
        if change.action in {"create", "start"}:
            backend.start(change.house)
        if change.reason == RESUME_HOLD:
            backend.cancel([change.house])  # once it is live again
        if change.action != "remove":
            backend.verify(change.house)
    if removed:
        backend.release(removed)
    return {"changes": [asdict(change) for change in changes], "verified": retained}
