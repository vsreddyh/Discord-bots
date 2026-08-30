"""Zen-only proxy: forwards to OpenCode Zen (no fallback)."""

from __future__ import annotations

import logging
import os

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("zen-proxy")

app = FastAPI(title="Zen Proxy")

# ── Backend ───────────────────────────────────────────────────
OPENCODE_API_KEY = os.environ.get("OPENCODE_API_KEY", "")
OPENCODE_BASE = "https://opencode.ai/zen/v1"

# Supported models — adding a model here auto-exposes it in /v1/models.
SUPPORTED_MODELS = [
    "muse-spark-1.2-free",
]
ZEN_MODELS = [
    {"id": model, "object": "model", "owned_by": "opencode-zen"}
    for model in SUPPORTED_MODELS
]

_client: httpx.AsyncClient | None = None


async def get_client() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(timeout=httpx.Timeout(120.0, connect=10.0))
    return _client


@app.on_event("shutdown")
async def shutdown():
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/v1/models")
async def list_models():
    return {"object": "list", "data": ZEN_MODELS}


async def _forward(
    url: str,
    headers: dict,
    body: dict,
    stream: bool,
) -> httpx.Response:
    client = await get_client()
    request = client.build_request("POST", url, headers=headers, json=body)
    return await client.send(request, stream=stream)


async def _build_response(resp: httpx.Response, stream: bool) -> Response:
    if stream and resp.status_code < 400:
        async def gen():
            try:
                async for chunk in resp.aiter_bytes():
                    yield chunk
            finally:
                await resp.aclose()

        return StreamingResponse(
            gen(),
            status_code=resp.status_code,
            headers={
                "content-type": "text/event-stream",
                "cache-control": "no-cache",
                "x-accel-buffering": "no",
            },
        )

    try:
        data = resp.json()
    except Exception:
        data = {"error": {"message": resp.text[:2000]}}
    if stream:
        await resp.aclose()
    return JSONResponse(content=data, status_code=resp.status_code)


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    try:
        body = await request.json()
    except Exception as exc:
        return JSONResponse(
            content={"error": {"message": f"invalid json: {exc}"}},
            status_code=400,
        )

    stream = body.get("stream", False)

    zen_headers = {
        "authorization": f"Bearer {OPENCODE_API_KEY}",
        "content-type": "application/json",
    }

    zen_resp = await _forward(
        f"{OPENCODE_BASE}/chat/completions",
        zen_headers,
        body,
        stream,
    )

    return await _build_response(zen_resp, stream)
