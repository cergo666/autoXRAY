#!/usr/bin/env python3
"""Поддельный Telegram Bot API для тестов: tests/mock_telegram.py <порт> <каталог>.
Очередь обновлений читается из <каталог>/queue.jsonl, все вызовы бота пишутся в <каталог>/sent.jsonl."""
import json, os, re, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, DIR = int(sys.argv[1]), sys.argv[2]
os.makedirs(DIR, exist_ok=True)
QUEUE, SENT = f"{DIR}/queue.jsonl", f"{DIR}/sent.jsonl"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        m = re.match(r"^/bot([^/]+)/(\w+)$", self.path)
        if not m:
            self.send_response(404); self.end_headers(); return
        token, method = m.groups()
        if "json" in self.headers.get("Content-Type", ""):
            payload = json.loads(body or b"{}")
        else:
            payload = {"multipart": True, "raw": body[:400].decode("latin1")}
        with open(SENT, "a") as f:
            f.write(json.dumps({"method": method, "token": token, "payload": payload}, ensure_ascii=False) + "\n")
        if "BAD" in token:   # «отозванный» токен: Telegram отвечает 401
            out = json.dumps({"ok": False, "error_code": 401, "description": "Unauthorized"}).encode()
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            return
        if method == "getMe":
            result = {"id": 1, "is_bot": True, "username": "axtest_bot", "first_name": "AX"}
        elif method == "getUpdates":
            offset = payload.get("offset", 0)
            end = time.time() + min(payload.get("timeout", 0), 2)
            while True:
                result = []
                if os.path.exists(QUEUE):
                    for line in open(QUEUE):
                        line = line.strip()
                        if line:
                            u = json.loads(line)
                            if u["update_id"] >= offset:
                                result.append(u)
                if result or time.time() >= end:
                    break
                time.sleep(0.2)
        else:
            result = {"message_id": int(time.time() * 1000) % 100000}
        out = json.dumps({"ok": True, "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
