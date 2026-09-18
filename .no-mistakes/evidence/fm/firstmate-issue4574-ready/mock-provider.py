#!/usr/bin/env python3
"""Local OpenAI-compatible provider used to drive real Pi workers offline.

Each account identity is a URL prefix (/work, /personal), so the request log
is the "billing record": it shows which provider identity a worker spent and
with which key. Usage: mock-provider.py <port> <log-file>
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
LOG = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"object":"list","data":[]}')

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        try:
            req = json.loads(body or b"{}")
        except ValueError:
            req = {}
        identity = self.path.split("/")[1] if self.path.count("/") > 1 else "?"
        with open(LOG, "a") as fh:
            fh.write(json.dumps({
                "t": time.strftime("%H:%M:%S"),
                "identity": identity,
                "path": self.path,
                "authorization": self.headers.get("Authorization", ""),
                "model": req.get("model"),
            }) + "\n")
        text = f"ACK from the {identity} account (model {req.get('model')})."
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        base = {"id": "mock-1", "object": "chat.completion.chunk",
                "created": int(time.time()), "model": req.get("model")}
        for chunk in (
            {**base, "choices": [{"index": 0, "delta": {"role": "assistant", "content": text}, "finish_reason": None}]},
            {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
            {**base, "choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20}},
        ):
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
