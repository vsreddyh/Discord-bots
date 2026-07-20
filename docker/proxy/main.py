"""Credit-aware proxy: forwards to OpenCode Zen, falls back to DeepInfra on credit errors."""

from __future__ import annotations

import json
import logging
import os

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response

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
    zen_models = [
        {"id": "deepseek-v4-flash-free", "object": "model", "owned_by": "opencode-zen"},
        {"id": "mimo-v2.5-free", "object": "model", "owned_by": "opencode-zen"},
    ]
    infra_models = [
        {"id": "deepseek-ai/DeepSeek-V4-Flash", "object": "model", "owned_by": "deepinfra"},
        {"id": "MiniMaxAI/MiniMax-M3", "object": "model", "owned_by": "deepinfra"},
    ]
    return {"object": "list", "data": zen_models + infra_models}


async def _forward(
    url: str,
    headers: dict,
    body: dict,
    stream: bool,
) -> httpx.Response:
    client = await get_client()
    return await client.post(
        url,
        headers=headers,
        json=body,
    )


def _build_response(resp: httpx.Response, stream: bool) -> Response:
    if stream:
        return Response(
            content=resp.iter_bytes(),
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
        return _build_response(zen_resp, stream)

    # ── Credit/payment error — try DeepInfra fallback ────────
    di_model = MODEL_MAP.get(model)
    if not di_model:
        logger.warning("No fallback mapping for model %s, returning Zen error", model)
        return _build_response(zen_resp, stream)

    if not DEEPINFRA_API_KEY:
        logger.warning("DEEPINFRA_API_KEY not set, cannot fall back")
        return _build_response(zen_resp, stream)

    logger.info("Credit error on %s via Zen — falling back to DeepInfra (%s)", model, di_model)

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

    return _build_response(di_resp, stream)
