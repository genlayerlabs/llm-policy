"""
codex_backend.py — call_provider for api_kind="openai_codex": the ChatGPT
subscription path via the Codex Responses endpoint
(POST https://chatgpt.com/backend-api/codex/responses), authenticated with the
token from `codex login` (see codex_auth.CodexAuth).

UNOFFICIAL / ToS-RISKY and undocumented — the endpoint shape can change without
notice. See docs/OPENAI-CODEX.md. The pure translation/aggregation helpers are
unit-tested; the live streaming call is not (no subscription in CI).
"""
from __future__ import annotations

import json
from typing import Any, Iterable

CODEX_BASE_URL = "https://chatgpt.com/backend-api/codex"


def _err(kind: str, status: int, latency_ms: int, message: str) -> dict:
    return {"ok": False, "error_kind": kind, "http_status": status,
            "latency_ms": latency_ms, "error_message": message}


def _messages_to_input(messages: list[dict]) -> list[dict]:
    """Chat-completions messages → Responses API `input` items. The Responses
    API accepts `{role, content}` with a plain string content as shorthand."""
    out = []
    for m in messages or []:
        role = m.get("role") or "user"
        content = m.get("content")
        if content is None:
            content = ""
        out.append({"role": role, "content": content})
    return out


def build_codex_body(request: dict) -> dict:
    """Build the Responses API request body from a router request."""
    body: dict = {
        "model":  request["served_model_id"],
        "input":  _messages_to_input(request.get("messages") or []),
        "stream": True,   # the Codex endpoint streams SSE
    }
    if request.get("max_tokens") is not None:
        body["max_output_tokens"] = request["max_tokens"]
    if request.get("temperature") is not None:
        body["temperature"] = request["temperature"]
    return body


def build_codex_headers(token: str, account_id: str | None,
                        extra: dict[str, str] | None = None) -> dict:
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type":  "application/json",
        "Accept":        "text/event-stream",
        "originator":    "codex_cli_rs",
        "User-Agent":    "codex_cli_rs",
    }
    if account_id:
        headers["chatgpt-account-id"] = account_id
    if extra:
        headers.update(extra)
    return headers


def aggregate_codex_sse(lines: Iterable[str], latency_ms: int) -> dict:
    """Fold a Codex Responses SSE stream into the router's response shape.

    Recognized events (by the `type` field of each `data:` JSON object):
      - response.output_text.delta  -> append `delta` to the text
      - response.completed          -> capture usage + finish
      - response.failed / error     -> map to an error
    """
    text_parts: list[str] = []
    finish_reason = "stop"
    usage: dict = {}
    err: dict | None = None

    for line in lines:
        line = line.strip()
        if not line or not line.startswith("data:"):
            continue
        payload = line[len("data:"):].strip()
        if payload == "[DONE]":
            break
        try:
            ev = json.loads(payload)
        except ValueError:
            continue
        etype = ev.get("type")
        if etype == "response.output_text.delta":
            if ev.get("delta"):
                text_parts.append(ev["delta"])
        elif etype == "response.completed":
            resp = ev.get("response") or {}
            usage = resp.get("usage") or usage
            if resp.get("status") == "incomplete":
                finish_reason = "length"
        elif etype in ("response.failed", "error"):
            msg = (ev.get("response") or ev).get("error") or ev.get("message") or "codex stream failed"
            err = _err("server_error", 0, latency_ms, str(msg))

    if err is not None:
        return err

    return {
        "ok": True,
        "latency_ms": latency_ms,
        "response": {
            "text":          "".join(text_parts),
            "tool_calls":    None,
            "finish_reason": finish_reason,
            "tokens_in":     usage.get("input_tokens"),
            "tokens_out":    usage.get("output_tokens"),
            "tokens_total":  usage.get("total_tokens"),
            "raw_model":     None,
        },
    }


def make_codex_async_call_provider(
    auth,
    base_url: str = CODEX_BASE_URL,
    timeout_s: float = 120.0,
    extra_headers: dict[str, str] | None = None,
):
    """Async call_provider for api_kind="openai_codex". `auth` is a
    codex_auth.CodexAuth (or anything with access_token()/account_id())."""
    import time
    import httpx

    async def call(request: dict) -> dict:
        token = auth.access_token()
        if not token:
            return _err("auth_error", 0, 0, "no codex access token (run `codex login`)")
        body = build_codex_body(request)
        headers = build_codex_headers(token, auth.account_id(), extra_headers)
        url = (request.get("base_url") or base_url).rstrip("/") + "/responses"
        timeout = (request.get("timeout_ms") or int(timeout_s * 1000)) / 1000.0

        t0 = time.monotonic()
        try:
            async with httpx.AsyncClient(timeout=timeout) as c:
                async with c.stream("POST", url, json=body, headers=headers) as resp:
                    latency = int((time.monotonic() - t0) * 1000)
                    if resp.status_code == 401:
                        return _err("auth_error", 401, latency, "codex token rejected")
                    if resp.status_code == 429:
                        return _err("rate_limit", 429, latency, "codex rate limited")
                    if resp.status_code >= 400:
                        detail = (await resp.aread()).decode("utf-8", "replace")[:500]
                        return _err("server_error", resp.status_code, latency, detail)
                    lines = [line async for line in resp.aiter_lines()]
            return aggregate_codex_sse(lines, int((time.monotonic() - t0) * 1000))
        except httpx.TimeoutException:
            return _err("timeout", 0, int((time.monotonic() - t0) * 1000), "codex request timed out")
        except (httpx.NetworkError, httpx.RequestError) as e:
            return _err("network_error", 0, int((time.monotonic() - t0) * 1000), str(e))

    return call
