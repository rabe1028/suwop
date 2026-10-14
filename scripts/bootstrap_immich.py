#!/usr/bin/env python3
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("SUWOP_IMMICH_URL", "http://127.0.0.1:2283").rstrip("/")
if urllib.parse.urlsplit(BASE).scheme not in {"http", "https"}:
    raise ValueError("Integration URL must use http or https")
if not BASE.endswith("/api"):
    BASE += "/api"
EMAIL = os.environ.get("IMMICH_TEST_EMAIL", "suwop@example.invalid")
PASSWORD = os.environ.get("IMMICH_TEST_PASSWORD", "SuwopIntegration123!")
NAME = "Suwop Integration"
# Deliberately register only HTTP(S); no file, FTP, or redirect handler.
OPENER = urllib.request.OpenerDirector()
OPENER.add_handler(urllib.request.HTTPHandler())
OPENER.add_handler(urllib.request.HTTPSHandler())
OPENER.add_handler(urllib.request.HTTPErrorProcessor())


def request(path, method="GET", body=None, token=None, timeout=10):
    data = None if body is None else json.dumps(body).encode()
    headers = {"Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)  # noqa: S310 - BASE and opener restrict requests to HTTP(S).
    with OPENER.open(req, timeout=timeout) as response:
        raw = response.read()
        return None if not raw else json.loads(raw)


def wait_ready():
    deadline = time.monotonic() + 180
    last = None
    while time.monotonic() < deadline:
        try:
            value = request("/server/ping", timeout=3)
            if value and value.get("res") == "pong":
                return
        except Exception as exc:
            last = exc
        time.sleep(2)
    raise RuntimeError(f"Immich did not become ready: {last}")


def main():
    wait_ready()
    config = request("/server/config")
    if not config.get("isInitialized"):
        request("/auth/admin-sign-up", "POST", {"email": EMAIL, "password": PASSWORD, "name": NAME})

    login = request("/auth/login", "POST", {"email": EMAIL, "password": PASSWORD})
    token = login["accessToken"]
    status = request("/auth/status", token=token)
    if not status.get("pinCode"):
        request(
            "/auth/pin-code",
            "POST",
            {"pinCode": os.environ.get("IMMICH_TEST_PIN", "123456")},
            token=token,
        )
    key = request(
        "/api-keys", "POST", {"name": "Suwop integration test", "permissions": ["all"]}, token=token
    )
    secret = key.get("secret")
    if not secret:
        raise RuntimeError("Immich API key response did not contain secret")
    print(secret)


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")[:1000]
        print(f"bootstrap failed: HTTP {exc.code}: {body}", file=sys.stderr)
        raise
