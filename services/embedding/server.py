#!/usr/bin/env python3
"""Minimal OpenAI-compatible /v1/embeddings server backed by fastembed.

PentAGI talks to embedding backends through the OpenAI wire format when
EMBEDDING_PROVIDER=openai. This process serves that format locally so the
stack needs no external embedding vendor.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_NAME = os.environ.get(
    "EMBED_MODEL",
    "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
)
PORT = int(os.environ.get("EMBED_PORT", "8080"))
CACHE_DIR = os.environ.get("EMBED_CACHE", "/opt/embedding/models")

print(f"loading model {MODEL_NAME} (cache={CACHE_DIR}) ...", flush=True)
from fastembed import TextEmbedding  # noqa: E402

model = TextEmbedding(model_name=MODEL_NAME, cache_dir=CACHE_DIR)
DIM = None


def estimate_tokens(texts):
    # 粗略估算：4 字符 ≈ 1 token，仅用于 usage 字段
    return max(1, sum(max(1, len(t) // 4) for t in texts))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/health", "/v1/health", "/healthz"):
            self._send(200, {"status": "ok", "model": MODEL_NAME, "dim": DIM})
        elif path in ("/v1/models", "/models"):
            self._send(200, {
                "object": "list",
                "data": [{"id": MODEL_NAME, "object": "model", "owned_by": "local-fastembed"}],
            })
        else:
            self._send(404, {"error": {"message": "not found", "type": "invalid_request_error"}})

    def do_POST(self):
        global DIM
        path = self.path.split("?")[0]
        if path not in ("/v1/embeddings", "/embeddings"):
            return self._send(404, {"error": {"message": "not found", "type": "invalid_request_error"}})

        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
        except Exception as exc:  # noqa: BLE001
            return self._send(400, {"error": {"message": f"bad json: {exc}", "type": "invalid_request_error"}})

        raw = payload.get("input")
        if isinstance(raw, str):
            texts = [raw]
        elif isinstance(raw, list):
            texts = [t if isinstance(t, str) else json.dumps(t) for t in raw]
        else:
            return self._send(400, {"error": {"message": "input must be string or array", "type": "invalid_request_error"}})

        if not texts:
            return self._send(400, {"error": {"message": "input is empty", "type": "invalid_request_error"}})

        try:
            vectors = [list(map(float, v)) for v in model.embed(texts)]
        except Exception as exc:  # noqa: BLE001
            return self._send(500, {"error": {"message": f"embed failed: {exc}", "type": "server_error"}})

        if vectors:
            DIM = len(vectors[0])

        tokens = estimate_tokens(texts)
        return self._send(200, {
            "object": "list",
            "data": [
                {"object": "embedding", "index": i, "embedding": v}
                for i, v in enumerate(vectors)
            ],
            "model": MODEL_NAME,
            "usage": {"prompt_tokens": tokens, "total_tokens": tokens},
        })

    def log_message(self, fmt, *args):  # 静默，避免刷日志
        pass


if __name__ == "__main__":
    print(f"listening on 0.0.0.0:{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
