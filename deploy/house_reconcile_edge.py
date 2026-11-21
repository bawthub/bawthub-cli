"""Only the DNS APIs needed for house origins; proxy/TLS policy is adopted."""

from __future__ import annotations

import base64
import json
import os
import ssl
from urllib.parse import quote, urlsplit
from urllib.request import HTTPRedirectHandler, HTTPSHandler, Request, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request(config, provider, method, path, payload=None):
    """Never include provider error bodies, headers or credentials in receipts."""
    settings = config[provider]
    base = settings["base_url"].rstrip("/")
    parsed = urlsplit(base)
    if parsed.scheme not in {"http", "https"} or parsed.username or parsed.password:
        raise ValueError("DNS API URL must be http(s), without credentials")
    headers = {"Accept": "application/json", "Content-Type": "application/json"}
    try:
        if provider == "unifi":
            headers["X-API-Key"] = os.environ[settings["api_key_env"]]
        else:
            pair = f"{os.environ[settings['username_env']]}:{os.environ[settings['password_env']]}"
            headers["Authorization"] = (
                "Basic " + base64.b64encode(pair.encode()).decode()
            )
        context = ssl.create_default_context()
        if settings.get("insecure_tls") is True:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        opener = build_opener(NoRedirect(), HTTPSHandler(context=context))
        body = None if payload is None else json.dumps(payload).encode()
        with opener.open(
            Request(base + path, data=body, method=method, headers=headers), timeout=15
        ) as response:
            raw = response.read(1048577)
        if len(raw) > 1048576:
            raise ValueError("oversized DNS API response")
        return json.loads(raw) if raw.strip() else None
    except Exception:
        raise RuntimeError(f"{provider} DNS API {method} failed") from None


class DNS:
    def __init__(self, config, owned, save, transport=request):
        self.config = config
        self.owned = owned
        self.save = save
        self.transport = transport

    def call(self, provider, method, path, payload=None):
        return self.transport(self.config, provider, method, path, payload)

    def path(self, provider):
        if provider == "unifi":
            site = quote(self.config[provider]["site"], safe="")
            return f"/v2/api/site/{site}/static-dns"
        return "/control/rewrite"

    def records(self, provider):
        path = self.path(provider)
        data = self.call(
            provider, "GET", path if provider == "unifi" else path + "/list"
        )
        if provider == "adguard" and isinstance(data, dict):
            if data.get("enabled") is False:
                raise ValueError("AdGuard DNS rewrites are globally disabled")
            data = data.get("data")
        if not isinstance(data, list) or any(not isinstance(row, dict) for row in data):
            raise ValueError(f"{provider} DNS inventory unavailable")
        return data

    def matching(self, provider, host, rows):
        key = "key" if provider == "unifi" else "domain"
        matches = [row for row in rows if row.get(key) == host]
        answer = self.config["answer"]
        if len(matches) > 1 or any(
            row.get("enabled") is False
            or row.get("value" if provider == "unifi" else "answer") != answer
            or (
                provider == "unifi"
                and (row.get("record_type") != "A" or row.get("enabled") is not True)
            )
            for row in matches
        ):
            raise ValueError(f"{provider} DNS conflict for {host}")
        return matches

    def plan(self, hosts):
        changes = []
        for provider in ("adguard", "unifi"):
            if provider not in self.config:
                continue
            rows = self.records(provider)
            for host in hosts:
                matches = self.matching(provider, host, rows)
                changes.append(
                    {
                        "provider": provider,
                        "host": host,
                        "action": "adopt" if matches else "create",
                    }
                )
        return changes

    def ensure(self, hosts):
        # Read BOTH providers first, so a known conflict is never discovered
        # only after another provider has already been changed.
        changes = self.plan(hosts)
        for change in changes:
            if change["action"] == "adopt":
                continue
            provider, host = change["provider"], change["host"]
            # Recheck immediately before the write; never replace a record.
            if self.matching(provider, host, self.records(provider)):
                continue
            if provider == "unifi":
                payload = {
                    "enabled": True,
                    "key": host,
                    "record_type": "A",
                    "value": self.config["answer"],
                    "ttl": 60,
                }
                result = self.call(provider, "POST", self.path(provider), payload)
                identifier = result.get("_id") if isinstance(result, dict) else None
                if not isinstance(identifier, str) or not identifier:
                    raise ValueError(
                        "UniFi created record needs manual ownership verification"
                    )
            else:
                payload = {
                    "domain": host,
                    "answer": self.config["answer"],
                    "enabled": True,
                }
                self.call(provider, "POST", self.path(provider) + "/add", payload)
                identifier = host
            self.owned.setdefault(provider, {})[host] = {
                "id": identifier,
                "answer": self.config["answer"],
            }
            self.save()
        for provider in ("adguard", "unifi"):
            if provider in self.config:
                rows = self.records(provider)
                if any(not self.matching(provider, host, rows) for host in hosts):
                    raise ValueError(f"{provider} DNS verification failed")

    def remove_owned(self, retained_hosts):
        for provider, records in self.owned.items():
            if provider not in self.config:
                raise ValueError("owned DNS provider configuration is missing")
            for host, owned in list(records.items()):
                if host in retained_hosts:
                    continue
                matches = self.matching(provider, host, self.records(provider))
                if matches:
                    row = matches[0]
                    if owned["answer"] != self.config["answer"]:
                        raise ValueError("owned DNS answer changed; refusing deletion")
                    if provider == "unifi":
                        if row.get("_id") != owned["id"]:
                            raise ValueError(
                                "owned DNS identity changed; refusing deletion"
                            )
                        self.call(
                            provider,
                            "DELETE",
                            self.path(provider) + "/" + quote(owned["id"], safe=""),
                        )
                    else:
                        self.call(
                            provider,
                            "POST",
                            self.path(provider) + "/delete",
                            {"domain": host, "answer": owned["answer"]},
                        )
                del records[host]
                self.save()
