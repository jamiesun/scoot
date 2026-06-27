#!/usr/bin/env python3
"""Tiny unauthenticated Streamable HTTP MCP server for the playground.

It needs no Authorization header and implements only the JSON-RPC methods Scoot
uses: initialize, notifications/initialized, tools/list, and tools/call. It is a
loopback smoke-test fixture for the mcp_call action, nothing more.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    server_version = "scoot-playground-mcp/1"

    def log_message(self, format, *args):  # noqa: A002 - signature matches BaseHTTPRequestHandler
        sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))

    def do_GET(self):
        if self.path == "/health":
            self._write_json(200, {"ok": True})
            return
        self._write_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/mcp":
            self._write_json(404, {"error": "not found"})
            return
        try:
            length = int(self.headers.get("content-length", "0"))
            payload = self.rfile.read(length).decode("utf-8")
            request = json.loads(payload)
        except Exception as exc:
            self._write_json(
                400,
                {
                    "jsonrpc": "2.0",
                    "id": None,
                    "error": {"code": -32700, "message": str(exc)},
                },
            )
            return

        method = request.get("method")
        request_id = request.get("id")

        if method == "initialize":
            self._write_json(
                200,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "protocolVersion": "2025-06-18",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "playground-echo", "version": "1"},
                    },
                },
            )
            return

        if method == "notifications/initialized":
            self._write_json(202, {"ok": True})
            return

        if method == "tools/list":
            self._write_json(
                200,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "tools": [
                            {
                                "name": "echo",
                                "description": "Return a playground MCP smoke-test marker.",
                                "inputSchema": {
                                    "type": "object",
                                    "properties": {"message": {"type": "string"}},
                                    "required": ["message"],
                                },
                            }
                        ]
                    },
                },
            )
            return

        if method == "tools/call":
            params = request.get("params") or {}
            args = params.get("arguments") or {}
            message = args.get("message", "")
            self._write_json(
                200,
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "content": [
                            {"type": "text", "text": "playground-echo-ok: %s" % message}
                        ],
                        "isError": False,
                    },
                },
            )
            return

        self._write_json(
            200,
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": "method not found"},
            },
        )

    def _write_json(self, status, body):
        data = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 18799
    httpd = ThreadingHTTPServer((host, port), Handler)
    print("listening http://%s:%d/mcp" % (host, port), flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
