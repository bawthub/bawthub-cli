#!/usr/bin/env python3
"""Render the tenant stack with synthetic inputs only; never start Docker services."""

import json
import os
import subprocess
from pathlib import Path

COMPOSE = Path(__file__).resolve().parent
KEY_MOUNT = "/run/bawthub-inspection-key"
SOCKET_MOUNT = "/run/bawthub-inspection"
WORKER = "inspection-renderer"
INIT = "inspection-socket-init"


def render(*overlays):
    env = {
        "PATH": os.environ["PATH"],
        "TENANT_ENV": "/dev/null",
        "APP_IMAGE_REF": "example.invalid/app:fixture",
        "TENANT_FRONTEND_IMAGE_REF": "example.invalid/frontend:fixture",
        "AGENT_BRIDGE_IMAGE_REF": "example.invalid/agent-bridge:fixture",
        "PLAYWRIGHT_MCP_IMAGE_REF": "example.invalid/playwright:fixture",
        "CRAWL4AI_IMAGE_REF": "example.invalid/crawl4ai:fixture",
        "POCKET_IMAGE_REF": "example.invalid/pocket:fixture",
        "VOICE_BACKEND_IMAGE_REF": "example.invalid/voice:fixture",
        "LLM_BAWT_POSTGRES_PASSWORD": "fixture-only-not-a-secret",
        "FRONTEND_DATABASE_URL": "postgresql://fixture@postgres/frontend",
        "VOICE_DATABASE_URL": "postgresql://fixture@postgres/voice",
        "AGENT_ORIGIN": "https://tenant.example",
        "BAWTHUB_AUTH_URL": "https://tenant.example",
        "BAWTHUB_AUTH_SESSIONS": "on",
    }
    command = [
        "docker",
        "compose",
        "--env-file",
        "/dev/null",
        "--project-name",
        "inspection-fixture",
    ]
    for overlay in ("base", "localdb", *overlays):
        command += ["-f", str(COMPOSE / f"docker-compose.{overlay}.yml")]
    command += ["config", "--no-env-resolution", "--format", "json"]
    return json.loads(subprocess.check_output(command, env=env))["services"]


def mounts(services, source, target):
    return {
        (name, volume["source"], volume["target"], volume.get("read_only", False))
        for name, service in services.items()
        for volume in service.get("volumes", [])
        if volume.get("source") == source or volume["target"] == target
    }


def main():
    default = render("agent-tools", "voice")
    assert not mounts(default, "inspection-key", KEY_MOUNT)
    assert not mounts(default, "inspection-socket", SOCKET_MOUNT)
    assert not ({WORKER, INIT} & default.keys())
    enabled = render("agent-tools", "voice", "inspection")
    assert {
        "app",
        "frontend",
        "agent-bridge",
        "playwright-mcp",
        "voice-backend",
    } <= enabled.keys()
    assert mounts(enabled, "inspection-key", KEY_MOUNT) == {
        ("app", "inspection-key", KEY_MOUNT, False),
        ("frontend", "inspection-key", KEY_MOUNT, True),
    }
    envs = {
        name: {
            k: v
            for k, v in service.get("environment", {}).items()
            if k.startswith("BAWTHUB_INSPECTION_KEY")
        }
        for name, service in enabled.items()
    }
    assert {name: env for name, env in envs.items() if env} == {
        "app": {
            "BAWTHUB_INSPECTION_KEY_EXPORT_FILE": f"{KEY_MOUNT}/key",
            "BAWTHUB_INSPECTION_KEY_EXPORT_UID": "1001",
        },
        "frontend": {"BAWTHUB_INSPECTION_KEY_FILE": f"{KEY_MOUNT}/key"},
    }
    assert mounts(enabled, "inspection-socket", SOCKET_MOUNT) == {
        (INIT, "inspection-socket", SOCKET_MOUNT, False),
        (WORKER, "inspection-socket", SOCKET_MOUNT, False),
        ("frontend", "inspection-socket", SOCKET_MOUNT, True),
    }
    for name in (INIT, WORKER):
        service = enabled[name]
        assert service["network_mode"] == "none"
        assert not any(
            service.get(k)
            for k in ("networks", "ports", "privileged", "env_file", "secrets")
        )
        assert service["read_only"] and service["cap_drop"] == ["ALL"]
        assert (
            service["image"] == enabled[WORKER]["image"]
            and "@sha256:" in service["image"]
        )
    worker = enabled[WORKER]
    assert worker["user"] == "1001:1001" and not worker.get("cap_add")
    assert worker.get("environment") == {"HOME": "/tmp"}
    assert len(enabled[INIT]["volumes"]) == 1
    assert len(worker["volumes"]) == 2
    script = next(volume for volume in worker["volumes"] if volume["type"] == "bind")
    assert (
        script["read_only"]
        and Path(script["source"]) == COMPOSE / "inspection-renderer.cjs"
    )
    print(
        "Inspection key and socket: absent by default, isolated mounts and networkless renderer when opted in"
    )


if __name__ == "__main__":
    main()
