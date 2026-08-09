"""Credit-aware proxy: forwards to OpenCode Zen, falls back to DeepInfra on credit errors."""

from __future__ import annotations

import json
import logging
import os
import time
from collections import deque
from datetime import datetime, timezone

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("zen-proxy")

app = FastAPI(title="Zen Proxy")

# ── Backends ────────────────────────────────────────────────
OPENCODE_API_KEY = os.environ.get("OPENCODE_API_KEY", "")
DEEPINFRA_API_KEY = os.environ.get("DEEPINFRA_API_KEY", "")

OPENCODE_BASE = "https://opencode.ai/zen/v1"
DEEPINFRA_BASE = "https://api.deepinfra.com/v1/openai"

# ── Model mapping: Zen model → DeepInfra model ──────────────
MODEL_MAP = {
    "deepseek-v4-flash-free": "deepseek-ai/DeepSeek-V4-Flash",
    "mimo-v2.5-free": "MiniMaxAI/MiniMax-M3",
}
# The advertised /v1/models list is DERIVED from MODEL_MAP so the two can
# never drift apart (they must always stay in sync).
ZEN_MODELS = [
    {"id": model, "object": "model", "owned_by": "opencode-zen"}
    for model in MODEL_MAP
]
DEEPINFRA_MODELS = [
    {"id": infra, "object": "model", "owned_by": "deepinfra"}
    for infra in MODEL_MAP.values()
]

# ── Credit/payment error keywords (mirrors Hermes' _is_payment_error) ──
PAYMENT_KEYWORDS = (
    "credits", "insufficient funds", "can only afford", "billing",
    "payment required", "out of funds", "run out of funds",
    "balance_depleted", "no usable credits",
    "model_not_supported_on_free_tier", "not available on the free tier",
    "requires a subscription", "upgrade for access",
    "quota exceeded", "quota_exceeded",
    "too many tokens per day", "daily limit",
    "tokens per day", "daily quota",
    "resource exhausted", "weekly usage limit", "weekly limit",
)

_client: httpx.AsyncClient | None = None

# ── Live usage tracking ─────────────────────────────────
# Aggregates every proxied request (in-memory; cleared on restart) so the
# actual token burn of the bots can be inspected live via GET /usage and in
# `docker logs` via the `USAGE ...` lines.
USAGE = {
    "since": datetime.now(timezone.utc).isoformat(),
    "requests": 0,
    "streams": 0,
    "errors": 0,
    "tokens": {"prompt": 0, "completion": 0, "total": 0},
    "by_model": {},
    "by_backend": {},
    "recent": deque(maxlen=200),
}


def _empty_agg() -> dict:
    return {"requests": 0, "errors": 0, "prompt": 0, "completion": 0, "total": 0}


def _record_usage(
    model: str,
    backend: str,
    status: int,
    stream: bool,
    usage: dict | None,
) -> None:
    """Fold one finished request into USAGE."""
    prompt = (usage or {}).get("prompt_tokens", 0)
    completion = (usage or {}).get("completion_tokens", 0)
    total = (usage or {}).get("total_tokens", 0) or (prompt + completion)
    error = status >= 400

    USAGE["requests"] += 1
    if stream:
        USAGE["streams"] += 1
    if error:
        USAGE["errors"] += 1

    USAGE["tokens"]["prompt"] += prompt
    USAGE["tokens"]["completion"] += completion
    USAGE["tokens"]["total"] += total

    agg = USAGE["by_model"].setdefault(model, _empty_agg())
    agg["requests"] += 1
    if error:
        agg["errors"] += 1
    agg["prompt"] += prompt
    agg["completion"] += completion
    agg["total"] += total

    b_agg = USAGE["by_backend"].setdefault(backend, _empty_agg())
    b_agg["requests"] += 1
    if error:
        b_agg["errors"] += 1
    b_agg["prompt"] += prompt
    b_agg["completion"] += completion
    b_agg["total"] += total

    USAGE["recent"].append({
        "at": datetime.now(timezone.utc).isoformat(),
        "model": model,
        "backend": backend,
        "status": status,
        "stream": stream,
        "prompt": prompt,
        "completion": completion,
        "total": total,
    })
    logger.info(
        "USAGE backend=%s model=%s status=%d stream=%s prompt=%d completion=%d total=%d",
        backend, model, status, stream, prompt, completion, total,
    )


def _parse_sse_usage(raw: bytes) -> dict | None:
    """Return the LAST `usage` object from SSE data lines, if any.

    Providers may emit a usage object in every chunk (growing completion),
    so we must keep the final one rather than the first.
    """
    found: dict | None = None
    for line in raw.split(b"\n"):
        line = line.strip()
        if not line.startswith(b"data:"):
            continue
        payload = line[5:].strip()
        if not payload or payload == b"[DONE]":
            continue
        try:
            obj = json.loads(payload)
        except Exception:
            continue
        if isinstance(obj, dict) and isinstance(obj.get("usage"), dict):
            found = obj["usage"]
    return found


async def get_client() -> httpx.AsyncClient:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(timeout=httpx.Timeout(120.0, connect=10.0))
    return _client


def _is_payment_error(resp: httpx.Response) -> bool:
    if resp.status_code == 402:
        return True
    if resp.status_code in (403, 404, 429, 400, None):
        try:
            body = resp.json()
            err_text = json.dumps(body).lower()
        except Exception:
            err_text = resp.text.lower()
        return any(kw in err_text for kw in PAYMENT_KEYWORDS)
    return False


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
    return {"object": "list", "data": ZEN_MODELS + DEEPINFRA_MODELS}


async def _forward(
    url: str,
    headers: dict,
    body: dict,
    stream: bool,
) -> httpx.Response:
    client = await get_client()
    request = client.build_request("POST", url, headers=headers, json=body)
    return await client.send(request, stream=stream)


async def _build_response(
    resp: httpx.Response,
    stream: bool,
    model: str,
    backend: str,
) -> Response:
    # Stream upstream success responses; always close the httpx response when
    # done, or the connection leaks (client disconnect included).
    if stream and resp.status_code < 400:
        async def gen():
            usage: dict | None = None
            buffer = b""
            try:
                async for chunk in resp.aiter_bytes():
                    buffer += chunk
                    if len(buffer) > 65536:
                        buffer = buffer[-65536:]  # keep the tail; usage arrives at the end
                    parsed = _parse_sse_usage(buffer)
                    if parsed:
                        usage = parsed
                    yield chunk
            finally:
                await resp.aclose()
                _record_usage(model, backend, resp.status_code, True, usage)

        return StreamingResponse(
            gen(),
            status_code=resp.status_code,
            headers={
                "content-type": "text/event-stream",
                "cache-control": "no-cache",
                "x-accel-buffering": "no",
            },
        )

    # Non-stream request, or an error response (body may already be consumed
    # by the payment-error check — never re-stream a read body).
    try:
        data = resp.json()
    except Exception:
        data = {"error": {"message": resp.text[:2000]}}
    usage = data.get("usage") if isinstance(data, dict) else None
    if stream:
        await resp.aclose()
    _record_usage(model, backend, resp.status_code, stream, usage)
    return JSONResponse(content=data, status_code=resp.status_code)


@app.get("/usage")
async def usage():
    """Live view of every proxied request since the proxy started."""
    return {
        "since": USAGE["since"],
        "requests": USAGE["requests"],
        "streams": USAGE["streams"],
        "errors": USAGE["errors"],
        "tokens": USAGE["tokens"],
        "by_model": USAGE["by_model"],
        "by_backend": USAGE["by_backend"],
        "recent": list(USAGE["recent"]),
    }


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    try:
        body = await request.json()
    except Exception as exc:
        return JSONResponse(
            content={"error": {"message": f"invalid json: {exc}"}},
            status_code=400,
        )

    model = body.get("model", "")
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

    if zen_resp.status_code < 400 or not _is_payment_error(zen_resp):
        return await _build_response(zen_resp, stream, model, "zen")

    # ── Credit/payment error — try DeepInfra fallback ────────
    di_model = MODEL_MAP.get(model)
    if not di_model:
        logger.warning("No fallback mapping for model %s, returning Zen error", model)
        return await _build_response(zen_resp, stream, model, "zen")

    if not DEEPINFRA_API_KEY:
        logger.warning("DEEPINFRA_API_KEY not set, cannot fall back")
        return await _build_response(zen_resp, stream, model, "zen")

    logger.info("Credit error on %s via Zen — falling back to DeepInfra (%s)", model, di_model)

    await zen_resp.aclose()

    di_body = dict(body)
    di_body["model"] = di_model

    di_headers = {
        "authorization": f"Bearer {DEEPINFRA_API_KEY}",
        "content-type": "application/json",
    }

    di_resp = await _forward(
        f"{DEEPINFRA_BASE}/chat/completions",
        di_headers,
        di_body,
        stream,
    )

    return await _build_response(di_resp, stream, di_model, "deepinfra")
