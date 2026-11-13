#!/usr/bin/env python3
"""Run the server allow-list through a real Xray and a local HTTP target."""

import argparse
import contextlib
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
# The stock geosite:private list already blocks some reserved suffixes.
# Use .com names with fixture-only DNS answers so the request reaches Freedom.
PRIVATE = "private.autoxray-e2e.com"
PUBLIC = "public.autoxray-e2e.com"


class Target(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.requests += 1
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"PRIVATE-TARGET")

    def log_message(self, *_args):
        pass


@contextlib.contextmanager
def xray_proxy(config, workdir):
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    config["inbounds"][0]["port"] = port
    cfg = workdir / "proxy.json"
    cfg.write_text(json.dumps(config), encoding="utf-8")
    subprocess.run(["xray", "run", "-test", "-c", cfg], check=True, timeout=10)
    log = workdir / "xray.log"
    with log.open("w") as output:
        proxy = subprocess.Popen(["xray", "run", "-c", cfg], stdout=output,
                                 stderr=subprocess.STDOUT)
    try:
        for _ in range(100):
            if proxy.poll() is not None:
                break
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    break
            except (ConnectionRefusedError, TimeoutError):
                time.sleep(0.05)
        else:
            raise AssertionError("Xray did not open its SOCKS port")
        if proxy.poll() is not None:
            raise AssertionError("Xray stopped while opening its SOCKS port")
        yield port, log
    except Exception:
        print(log.read_text(encoding="utf-8"))
        raise
    finally:
        proxy.terminate()
        try:
            proxy.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proxy.kill()
            proxy.wait()


def fetch(proxy_port, domain, port):
    return subprocess.run(
        ["curl", "-fsS", "--max-time", "4", "--noproxy", "",
         "--socks5-hostname", f"127.0.0.1:{proxy_port}", f"http://{domain}:{port}/ok.txt"],
        capture_output=True, text=True, timeout=6,
    )


def render_config(workdir, public_target):
    state = {
        "mode": "direct", "domain": "policy.example", "users": [],
        "socks": {"user": "u", "pass": "p"}, "paths": {"xhttp": "test"},
        "server_policy": {"allow_domains": [PRIVATE, PUBLIC]},
    }
    for name, data in (("state", state), ("traffic", {}), ("bans", [])):
        (workdir / f"{name}.json").write_text(json.dumps(data), encoding="utf-8")
    env = {**os.environ, "AX_DRY": "1", "AX_UNIT_TEST": "1", "AX_ETC": str(workdir),
           "AX_TEMPLATES": str(ROOT / "templates")}
    result = subprocess.run(
        ["bash", "-ec", 'source ./autoxray; render_xray_with_rules "$STATE"'],
        cwd=ROOT, env=env, check=True, capture_output=True, text=True, timeout=10,
    )
    config = json.loads(result.stdout)
    # Keep the production DNS strategy, routing and outbounds. Use local
    # listeners and static DNS answers so the test needs no live DNS or TLS.
    config["log"] = {"loglevel": "info"}
    config["inbounds"] = [{
        "tag": "test-socks", "listen": "127.0.0.1", "protocol": "mixed",
        "settings": {"auth": "noauth"},
    }]
    config["dns"]["hosts"] = {PRIVATE: "127.0.0.1", PUBLIC: public_target}
    config["dns"]["servers"] = ["localhost"]
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--public-target", help="Local, non-private HTTP fixture on port 8080")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as directory, http.server.HTTPServer(("127.0.0.1", 0), Target) as target:
        workdir = Path(directory)
        config = render_config(workdir, args.public_target or "93.184.216.34")
        outbound = next(out for out in config["outbounds"] if out["tag"] == "ax-policy-direct")
        final_rules = outbound["settings"].pop("finalRules")
        target.requests = 0
        thread = threading.Thread(target=target.serve_forever, daemon=True)
        thread.start()
        try:
            # Negative control: a real connection succeeds with the guard removed.
            with xray_proxy(config, workdir) as (port, _log):
                control = fetch(port, PRIVATE, target.server_port)
                if control.returncode != 0 or control.stdout != "PRIVATE-TARGET":
                    raise AssertionError(f"Private target is unreachable in control: {control.stderr}")
            outbound["settings"]["finalRules"] = final_rules
            with xray_proxy(config, workdir) as (port, log):
                private = fetch(port, PRIVATE, target.server_port)
                if private.returncode == 0 or target.requests != 1:
                    raise AssertionError("Allowed hostname reached the private target")
                if f"blocked target: tcp:127.0.0.1:{target.server_port}" not in log.read_text(encoding="utf-8"):
                    raise AssertionError("Xray did not block the destination in Freedom")
                if args.public_target:
                    public = fetch(port, PUBLIC, 8080)
                    if public.returncode != 0 or public.stdout.strip() != "TARGET-OK":
                        raise AssertionError(f"Allowed public target failed: {public.stderr}")
        finally:
            target.shutdown()
            thread.join()
    print("OK: Xray blocks a private destination reached through an allowed domain")
    if args.public_target:
        print("OK: Xray connects to an allowed public destination")


if __name__ == "__main__":
    main()
