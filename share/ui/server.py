#!/usr/bin/env python3
"""The Merge Goblin's control panel — a local web UI.

Deliberately boring: python3 stdlib only, binds to 127.0.0.1, and every action
shells out to the CLI rather than reimplementing anything. The CLI stays
the single source of truth; this is just a face for it.

Started by `goblin ui`. Not intended to be run directly.
"""

import http.server
import json
import os
import secrets
import socket
import subprocess
import sys
import threading
import time
import urllib.parse

BOB = os.environ.get("GOBLIN_CLI") or "goblin"
GOBLIN_HOME = os.environ.get("GOBLIN_HOME") or os.path.expanduser("~/.goblin")
UI_DIR = os.path.dirname(os.path.abspath(__file__))
TOKEN = os.environ.get("GOBLIN_UI_TOKEN") or secrets.token_urlsafe(24)

# Verbs the UI is allowed to invoke. Anything not listed is refused, so a stray
# request can never turn into arbitrary command execution.
ALLOWED = {
    "on": 0, "off": 0, "pause": 0, "resume": 0, "toggle": 0,
    "snooze1h": 0, "snoozetomorrow": 0, "clearsnooze": 0,
    "budget": 1, "provider": 2, "repos": 2, "fleet": 2,
    "config": 3, "doctor": 1, "run": 4, "fix-account": 0, "status": 1,
}

_cache = {"providers": None, "at": 0}
_lock = threading.Lock()


def run_bob(args, timeout=120):
    try:
        p = subprocess.run(
            [BOB] + args,
            capture_output=True, text=True, timeout=timeout,
            env={**os.environ, "GOBLIN_HOME": GOBLIN_HOME},
        )
        return {"ok": p.returncode == 0, "code": p.returncode,
                "out": p.stdout.strip(), "err": p.stderr.strip()}
    except subprocess.TimeoutExpired:
        return {"ok": False, "code": 124, "out": "", "err": "timed out"}
    except FileNotFoundError:
        return {"ok": False, "code": 127, "out": "", "err": f"{BOB} not found"}


def read_json(path, default):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return default


def providers(force=False):
    """Probing spawns three CLIs, so cache it — the page polls every few seconds."""
    with _lock:
        fresh = time.time() - _cache["at"] < 30
        if _cache["providers"] is not None and fresh and not force:
            return _cache["providers"]
    res = run_bob(["provider", "list"], timeout=30)
    out = []
    for line in res["out"].splitlines():
        # Read the current-provider marker rather than slicing a fixed-width
        # prefix off the front: run_bob strips stdout, so the first row arrives
        # without its indent and a blind line[2:] ate two letters of its name.
        line = line.strip()
        if not line:
            continue
        current = line.startswith("▸")
        if current:
            line = line[1:].lstrip()
        parts = line.split()
        if not parts:
            continue
        rest = " ".join(parts[1:])
        out.append({
            "id": parts[0],
            "current": current,
            "state": "ready" if rest.startswith("ready") else ("no auth" if rest.startswith("no auth") else "missing"),
            "detail": rest,
        })
    with _lock:
        _cache["providers"] = out
        _cache["at"] = time.time()
    return out


def history(limit=25):
    path = os.path.join(GOBLIN_HOME, "events.jsonl")
    rows = []
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if line:
                    try:
                        rows.append(json.loads(line))
                    except ValueError:
                        pass
    except OSError:
        return []
    return rows[-limit:][::-1]


def state(force_providers=False):
    run_bob(["status", "--json"], timeout=20)          # refreshes the state cache
    st = read_json(os.path.join(GOBLIN_HOME, "uistate.json"), {})
    cfg = read_json(os.path.join(GOBLIN_HOME, "config.json"), {})
    return {
        "status": st,
        "config": cfg,
        "providers": providers(force=force_providers),
        "history": history(),
        "home": GOBLIN_HOME,
    }


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "goblin-ui"

    def log_message(self, *_args):
        pass                                            # don't spam the terminal

    # Only ever talk to the loopback caller, and only with the right token.
    # Also pin Host: a browser tricked into resolving some name to 127.0.0.1
    # would otherwise be able to drive this.
    def _authorised(self, params):
        host = (self.headers.get("Host") or "").split(":")[0]
        if host not in ("127.0.0.1", "localhost"):
            return False
        tok = params.get("token", [None])[0] or self.headers.get("X-Goblin-Token")
        return secrets.compare_digest(str(tok or ""), TOKEN)

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else str(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        try:
            self.wfile.write(data)
        except BrokenPipeError:
            pass

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)

        if u.path in ("/", "/index.html"):
            if not self._authorised(q):
                return self._send(403, "forbidden", "text/plain")
            with open(os.path.join(UI_DIR, "app.html"), "rb") as fh:
                page = fh.read().replace(b"__TOKEN__", TOKEN.encode())
            return self._send(200, page, "text/html; charset=utf-8")

        if u.path == "/goblin.svg":
            try:
                with open(os.path.join(UI_DIR, "goblin.svg"), "rb") as fh:
                    return self._send(200, fh.read(), "image/svg+xml")
            except OSError:
                return self._send(404, "")

        if u.path == "/api/state":
            if not self._authorised(q):
                return self._send(403, json.dumps({"error": "forbidden"}))
            force = q.get("providers", [""])[0] == "refresh"
            return self._send(200, json.dumps(state(force_providers=force)))

        return self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        if u.path != "/api/action":
            return self._send(404, json.dumps({"error": "not found"}))
        try:
            n = int(self.headers.get("Content-Length") or 0)
            payload = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, TypeError):
            return self._send(400, json.dumps({"error": "bad json"}))

        if not self._authorised({"token": [payload.get("token")]}):
            return self._send(403, json.dumps({"error": "forbidden"}))

        verb = str(payload.get("verb") or "")
        args = [str(a) for a in (payload.get("args") or [])]
        if verb not in ALLOWED or len(args) > ALLOWED[verb]:
            return self._send(400, json.dumps({"error": f"refused: {verb}"}))

        # A review takes minutes; don't hold the request open for it.
        if verb == "run" and "--plan" not in args:
            subprocess.Popen([BOB, "run"] + args,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             env={**os.environ, "GOBLIN_HOME": GOBLIN_HOME})
            return self._send(200, json.dumps({"ok": True, "out": "review started", "state": state()}))

        res = run_bob([verb] + args)
        if verb == "provider":
            with _lock:
                _cache["at"] = 0                        # force a re-probe next read
        res["state"] = state()
        return self._send(200, json.dumps(res))


def pick_port(preferred=0):
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", preferred))
        return s.getsockname()[1]
    finally:
        s.close()


def main():
    port = int(os.environ.get("GOBLIN_UI_PORT") or 0) or pick_port()
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    url = f"http://127.0.0.1:{port}/?token={TOKEN}"
    print(url, flush=True)

    urlfile = os.environ.get("GOBLIN_UI_URLFILE")
    if urlfile:
        try:
            with open(urlfile, "w") as fh:
                fh.write(url)
        except OSError:
            urlfile = None

    if os.environ.get("GOBLIN_UI_OPEN", "1") == "1":
        subprocess.Popen(["open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        # Never leave a URL behind pointing at a port nobody is listening on.
        if urlfile:
            try:
                os.remove(urlfile)
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())
