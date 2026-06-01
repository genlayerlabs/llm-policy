"""
OpenAI ChatGPT-subscription provider (api_kind="openai_codex"): token
read/refresh from auth.json, Responses-API request translation, SSE
aggregation, and the api_kind dispatcher. The live streaming HTTP call is not
exercised (no subscription in CI); everything around it is.
"""
from __future__ import annotations

import base64
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "hosts" / "python"))

from codex_auth import CodexAuth, _extract_tokens, _jwt_exp  # noqa: E402
import codex_backend as cb  # noqa: E402
from llm_router_host import make_api_kind_dispatcher  # noqa: E402


def _jwt(exp: int) -> str:
    def b64(d): return base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
    return f"{b64({'alg': 'none'})}.{b64({'exp': exp})}.sig"


class _Resp:
    def __init__(self, status, payload):
        self.status_code = status
        self._payload = payload
    def json(self):
        return self._payload


# ---- codex_auth --------------------------------------------------------

def test_extract_tokens_accepts_nested_and_top_level():
    nested = _extract_tokens({"tokens": {"access_token": "a", "account_id": "acc"}})
    assert nested["access_token"] == "a" and nested["account_id"] == "acc"
    flat = _extract_tokens({"access_token": "b", "refresh_token": "r"})
    assert flat["access_token"] == "b" and flat["refresh_token"] == "r"


def test_jwt_exp_reads_expiry():
    assert _jwt_exp(_jwt(1_900_000_000)) == 1_900_000_000.0
    assert _jwt_exp("not-a-jwt") is None


def test_access_token_reads_from_auth_json(tmp_path):
    p = tmp_path / "auth.json"
    p.write_text(json.dumps({"tokens": {
        "access_token": _jwt(1_900_000_000), "account_id": "acc-1"}}))
    auth = CodexAuth(p, now=lambda: 1_000_000_000)
    assert auth.access_token().startswith("ey") or "." in auth.access_token()
    assert auth.account_id() == "acc-1"


def test_expired_token_triggers_refresh_and_writeback(tmp_path):
    p = tmp_path / "auth.json"
    p.write_text(json.dumps({"tokens": {
        "access_token": _jwt(1_000),          # long expired
        "refresh_token": "refresh-abc",
        "account_id": "acc-1",
    }}))
    calls = []
    new_token = _jwt(1_900_000_000)
    def fake_post(url, json):
        calls.append((url, json))
        return _Resp(200, {"access_token": new_token, "refresh_token": "refresh-def"})

    auth = CodexAuth(p, http_post=fake_post, now=lambda: 1_500_000_000)
    tok = auth.access_token()
    assert tok == new_token, "refreshed token returned"
    assert calls and calls[0][1]["grant_type"] == "refresh_token"
    assert calls[0][1]["refresh_token"] == "refresh-abc"
    # written back to disk
    on_disk = json.loads(p.read_text())["tokens"]
    assert on_disk["access_token"] == new_token
    assert on_disk["refresh_token"] == "refresh-def"


def test_missing_auth_json_yields_no_token(tmp_path):
    auth = CodexAuth(tmp_path / "nope.json")
    assert auth.access_token() is None


# ---- codex_backend translation -----------------------------------------

def test_messages_to_input():
    items = cb._messages_to_input([
        {"role": "system", "content": "be terse"},
        {"role": "user", "content": "hi"},
    ])
    assert items == [
        {"role": "system", "content": "be terse"},
        {"role": "user", "content": "hi"},
    ]


def test_build_codex_body_uses_responses_shape():
    body = cb.build_codex_body({
        "served_model_id": "gpt-5.5-codex",
        "messages": [{"role": "user", "content": "hi"}],
        "max_tokens": 256,
        "temperature": 0.3,
    })
    assert body["model"] == "gpt-5.5-codex"
    assert body["stream"] is True
    assert body["input"][0]["role"] == "user"
    assert body["max_output_tokens"] == 256
    assert body["temperature"] == 0.3


def test_build_codex_headers_sets_account_id():
    h = cb.build_codex_headers("tok", "acc-9")
    assert h["Authorization"] == "Bearer tok"
    assert h["chatgpt-account-id"] == "acc-9"
    assert h["Accept"] == "text/event-stream"


def test_aggregate_sse_collects_text_and_usage():
    lines = [
        'data: {"type": "response.output_text.delta", "delta": "Hel"}',
        'data: {"type": "response.output_text.delta", "delta": "lo"}',
        'data: {"type": "response.completed", "response": {"usage": '
        '{"input_tokens": 5, "output_tokens": 2, "total_tokens": 7}}}',
        "data: [DONE]",
    ]
    out = cb.aggregate_codex_sse(lines, latency_ms=12)
    assert out["ok"] is True
    assert out["response"]["text"] == "Hello"
    assert out["response"]["tokens_total"] == 7
    assert out["latency_ms"] == 12


def test_aggregate_sse_maps_failure_to_error():
    lines = ['data: {"type": "response.failed", "response": {"error": "boom"}}']
    out = cb.aggregate_codex_sse(lines, latency_ms=3)
    assert out["ok"] is False
    assert out["error_kind"] == "server_error"
    assert "boom" in out["error_message"]


# ---- dispatcher --------------------------------------------------------

@pytest.mark.asyncio
async def test_dispatcher_routes_by_api_kind():
    seen = {}
    async def default(req): seen["default"] = req; return {"ok": True, "via": "default"}
    async def codex(req): seen["codex"] = req; return {"ok": True, "via": "codex"}

    dispatch = make_api_kind_dispatcher(default=default, handlers={"openai_codex": codex})
    r1 = await dispatch({"api_kind": "openai_compatible"})
    r2 = await dispatch({"api_kind": "openai_codex"})
    assert r1["via"] == "default"
    assert r2["via"] == "codex"
