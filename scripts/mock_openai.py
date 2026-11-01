#!/usr/bin/env python3
"""Local stand-in for the OpenAI Image API, for testing without spending credit.

Usage: python3 scripts/mock_openai.py [delay-seconds] [fail-first-n]   (listens on 127.0.0.1:8765)
fail-first-n: answer the first N generation requests with 503 + Retry-After: 2 (to exercise retries).
Then launch a DEBUG build with: -OpenAIBaseURL http://127.0.0.1:8765/v1
"""
import base64, json, sys, time, zlib, struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DELAY = float(sys.argv[1]) if len(sys.argv) > 1 else 20
FAIL_FIRST = int(sys.argv[2]) if len(sys.argv) > 2 else 0
failures = 0

def png(w, h, seed):
    rows = []
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            row += bytes(((x * 255 // w + seed) % 256, (y * 255 // h) % 256, (seed * 3) % 256))
        rows.append(bytes(row))
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 6)) + chunk(b"IEND", b""))

class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        print("GET", self.path, flush=True); self._send(200, {"object": "list", "data": []})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        print("POST", self.path, body.get("prompt"), "n=", body.get("n"), "auth=", self.headers.get("Authorization", "")[:14], flush=True)
        global failures
        if failures < FAIL_FIRST:
            failures += 1
            payload = json.dumps({"error": {"message": "The server is overloaded.", "type": "server_error", "code": None}}).encode()
            self.send_response(503); self.send_header("Content-Type", "application/json"); self.send_header("Retry-After", "2")
            self.send_header("Content-Length", str(len(payload))); self.end_headers(); self.wfile.write(payload)
            print("  503 (failure", failures, "of", FAIL_FIRST, ")", flush=True)
            return
        time.sleep(DELAY)
        imgs = [{"b64_json": base64.b64encode(png(512, 512, i * 70 + int(time.time()) % 200)).decode()} for i in range(body.get("n", 1))]
        self._send(200, {"created": int(time.time()), "size": "1024x1024", "quality": "high", "background": "opaque",
                         "output_format": "png", "data": imgs, "usage": {"input_tokens": 9, "output_tokens": 4160, "total_tokens": 4169}})
        print("  responded", flush=True)
    def log_message(self, *a): pass

ThreadingHTTPServer(("127.0.0.1", 8765), H).serve_forever()
