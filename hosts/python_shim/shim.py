"""
shim.py — OpenAI-compatible HTTP façade in front of router.lua.

Any client that speaks /v1/chat/completions can POST OpenAI-shaped requests.
The shim translates them to a router contract, runs `router.execute`, and
translates the router result back to an OpenAI response. Provider selection,
fallback, retries and provider auth all live on the router side; the client
sees a single endpoint.

Model field convention (explicit prefixes, no magic):

    model = ""                          -> default_profile
    model = "profile:cheap_explore"     -> contract.profile
    model = "family:deepseek-v3"        -> contract.requirements.model_family
    model = "pin:<provider>/<family>"   -> contract.requirements.pin
    model = anything else               -> default_profile (logged)

Streaming is not supported. Requests with `stream: true` get a 400.

Concurrency note: lupa serializes Lua execution. FastAPI's threadpool will
queue concurrent /v1/chat/completions calls behind the single LuaRuntime.
Fine for one or a handful of concurrent clients; for hundreds-to-thousands
of concurrent callers, use a luerl-based host instead.
"""
from __future__ import annotations

import time
import uuid
from typing import Any

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict


# Profile name used when nothing else can be inferred. Replaced via
# create_app(default_profile=...).
DEFAULT_PROFILE_FALLBACK = "default"


class ChatRequest(BaseModel):
    """Permissive OpenAI /v1/chat/completions body.

    Unknown fields are kept (`extra="allow"`) so future OpenAI fields don't
    require shim edits; the shim only forwards the fields the router knows.
    """
    model_config = ConfigDict(extra="allow")

    model: str = ""
    messages: list[dict] = []
    stream: bool = False
    tools: list[dict] | None = None
    tool_choice: Any = None
    response_format: dict | None = None
    temperature: float | None = None
    seed: int | None = None
    max_tokens: int | None = None


def create_app(host, default_profile: str = DEFAULT_PROFILE_FALLBACK) -> FastAPI:
    """Build a FastAPI app wired to a pre-initialized LLMRouterHost.

    The host must already have `init()` called and `host.call_provider`
    pointing at something that actually talks to providers (or a mock for
    tests).
    """
    app = FastAPI(title="llm-router shim", docs_url=None, redoc_url=None)

    @app.get("/healthz")
    def healthz():
        info = host.info()
        return {"ok": True, "initialized": info.get("initialized", False)}

    @app.get("/v1/models")
    def list_models():
        info = host.info()
        ids = [f"profile:{p}" for p in (info.get("profile_names") or [])]
        ids += [f"family:{f}" for f in (info.get("models_loaded") or [])]
        return {"object": "list", "data": [{"id": i, "object": "model"} for i in ids]}

    @app.post("/v1/chat/completions")
    async def chat_completions(req: ChatRequest):
        if req.stream:
            return _openai_error(
                "streaming not supported by llm-router shim",
                "invalid_request_error", 400,
            )

        contract = _request_to_contract(req, default_profile)
        # Async driver: the Lua VM is touched only between awaits, so one
        # shared LuaRuntime overlaps many concurrent requests on one loop.
        result = await host.execute_async(contract)

        if result.get("ok"):
            return _router_response_to_openai(result, req.model)
        return _openai_error_from_router(result)

    return app


def _request_to_contract(req: ChatRequest, default_profile: str) -> dict:
    model = (req.model or "").strip()
    contract: dict = {"messages": req.messages or []}

    if not model:
        contract["profile"] = default_profile
    elif model.startswith("profile:"):
        contract["profile"] = model[len("profile:"):] or default_profile
    elif model.startswith("family:"):
        family = model[len("family:"):]
        contract["profile"] = default_profile
        if family:
            contract["requirements"] = {"model_family": family}
    elif model.startswith("pin:"):
        rest = model[len("pin:"):]
        contract["profile"] = default_profile
        if "/" in rest:
            provider, family = rest.split("/", 1)
            if provider and family:
                contract["requirements"] = {"pin": {"provider": provider, "model": family}}
    else:
        contract["profile"] = default_profile

    if req.tools is not None:
        contract["tools"] = req.tools
    if req.tool_choice is not None:
        contract["tool_choice"] = req.tool_choice
    if req.response_format is not None:
        contract["response_format"] = req.response_format
    if req.temperature is not None:
        contract["temperature"] = req.temperature
    if req.seed is not None:
        contract["seed"] = req.seed
    if req.max_tokens is not None:
        contract["max_tokens"] = req.max_tokens

    return contract


def _router_response_to_openai(result: dict, requested_model: str) -> dict:
    response = result.get("response") or {}
    chosen = result.get("chosen") or {}

    message: dict = {"role": "assistant", "content": response.get("text") or ""}
    if response.get("tool_calls"):
        message["tool_calls"] = response["tool_calls"]

    out: dict = {
        "id": f"chatcmpl-{uuid.uuid4().hex[:24]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": (
            response.get("raw_model")
            or chosen.get("served_model_id")
            or requested_model
            or ""
        ),
        "choices": [{
            "index": 0,
            "message": message,
            "finish_reason": response.get("finish_reason") or "stop",
        }],
    }

    usage = {}
    if response.get("tokens_in") is not None:
        usage["prompt_tokens"] = response["tokens_in"]
    if response.get("tokens_out") is not None:
        usage["completion_tokens"] = response["tokens_out"]
    if response.get("tokens_total") is not None:
        usage["total_tokens"] = response["tokens_total"]
    if usage:
        out["usage"] = usage

    # Non-standard router metadata: ignored by OpenAI clients, useful for debugging.
    out["x_router"] = {
        "provider": chosen.get("provider_id"),
        "model_family": chosen.get("model_family"),
        "served_model_id": chosen.get("served_model_id"),
    }
    return out


def _openai_error_from_router(result: dict) -> JSONResponse:
    error_kind = str(result.get("error") or "unknown")

    # The router returns either a bare kind (abort path: bad_request /
    # context_overflow; or no_candidates) or "exhausted: <kind>" when it tried
    # candidates. Normalize to the bare kind before mapping so both forms map
    # the same way (e.g. an aborting bad_request → 400, not 502).
    kind = error_kind[len("exhausted: "):] if error_kind.startswith("exhausted: ") else error_kind

    if "not initialized" in error_kind:
        status = 500
    elif kind == "no_candidates":
        status = 503
    elif kind == "auth_error":
        status = 401
    elif kind == "rate_limit":
        status = 429
    elif kind in ("bad_request", "context_overflow"):
        status = 400
    else:
        status = 502

    # router's error strings already start with "exhausted: " when candidates
    # were tried — don't double-prefix.
    message = error_kind if error_kind.startswith("exhausted:") else f"router: {error_kind}"
    return JSONResponse(
        status_code=status,
        content={"error": {
            "message": message,
            "type": "router_error",
            "code": error_kind,
        }},
    )


def _openai_error(message: str, type_: str, status: int) -> JSONResponse:
    return JSONResponse(
        status_code=status,
        content={"error": {"message": message, "type": type_, "code": None}},
    )
