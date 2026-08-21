#!/usr/bin/env python3
from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json


class Handler(BaseHTTPRequestHandler):
    server_version = "LumiMockOllama/1"

    def log_message(self, format: str, *args) -> None:
        return

    def _json(self, status: int, payload: dict) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        if self.path == "/api/tags":
            self._json(200, {"models": [{"name": "lumi-mock"}]})
            return
        self._json(404, {"error": "not_found"})

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid_json"})
            return

        if self.path == "/api/embed":
            values = payload.get("input") or []
            if isinstance(values, str):
                values = [values]
            embeddings = [[1.0, 0.0, 0.0, 0.0] for _ in values]
            self._json(200, {"model": payload.get("model", "lumi-mock-embed"), "embeddings": embeddings})
            return

        if self.path == "/api/chat":
            content = "Lumi local acceptance OK"
            if payload.get("stream") is True:
                lines = [
                    json.dumps({"message": {"role": "assistant", "content": "Lumi local "}, "done": False}),
                    json.dumps({"message": {"role": "assistant", "content": "acceptance OK"}, "done": False}),
                    json.dumps({"message": {"role": "assistant", "content": ""}, "done": True}),
                ]
                data = ("\n".join(lines) + "\n").encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/x-ndjson")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            else:
                self._json(200, {"model": payload.get("model", "lumi-mock"), "message": {"role": "assistant", "content": content}, "done": True})
            return

        self._json(404, {"error": "not_found"})


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
