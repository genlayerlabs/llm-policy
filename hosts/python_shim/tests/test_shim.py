"""
Integration tests for the FastAPI shim.

These boot a real LLMRouterHost backed by mock provider responses (set via
set_mock_response). The router runs end-to-end inside lupa; only the
outbound HTTP to the upstream provider is mocked.

Run from repo root:
    pytest hosts/python_shim/tests -v
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "hosts" / "python"))

from llm_router_host import LLMRouterHost  # noqa: E402

from hosts.python_shim.shim import create_app  # noqa: E402


def _ok_response(text: str = "hi back") -> dict:
    return {
        "ok": True,
        "latency_ms": 10,
        "response": {
            "text":          text,
            "tool_calls":    None,
            "finish_reason": "stop",
            "tokens_in":     7,
            "tokens_out":    3,
            "tokens_total":  10,
            "raw_model":     "mock-model-id",
        },
    }


def _err_response(kind: str = "server_error", status: int = 500) -> dict:
    return {
        "ok":            False,
        "error_kind":    kind,
        "http_status":   status,
        "latency_ms":    5,
        "error_message": f"mock {kind}",
    }


@pytest.fixture
def host():
    h = LLMRouterHost(
        router_path=ROOT / "router.lua",
        config_path=ROOT / "config.example.lua",
        metrics_path=ROOT / "metrics.example.lua",
        now_ms=lambda: 1_000_000,
    )
    h.init()
    return h


@pytest.fixture
def client(host):
    app = create_app(host, default_profile="default")
    return TestClient(app)


# ---- liveness / introspection ------------------------------------------

def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"ok": True, "initialized": True}


def test_list_models_exposes_profiles_and_families(client):
    r = client.get("/v1/models")
    assert r.status_code == 200
    ids = {m["id"] for m in r.json()["data"]}
    assert "profile:default" in ids
    assert "profile:cheap_explore" in ids
    assert any(i.startswith("family:") for i in ids)


# ---- model field convention --------------------------------------------

def test_empty_model_uses_default_profile(client, host):
    # Set a mock for every (provider, family) in the catalog so SOME candidate
    # succeeds regardless of which one default picks.
    for prov, fam in _all_pairs(host):
        host.set_mock_response(prov, fam, _ok_response("ok"))
    r = client.post("/v1/chat/completions", json={"model": "", "messages": [{"role": "user", "content": "hi"}]})
    assert r.status_code == 200
    body = r.json()
    assert body["choices"][0]["message"]["content"] == "ok"
    assert body["x_router"]["provider"] is not None


def test_profile_prefix_routes_to_that_profile(client, host):
    for prov, fam in _all_pairs(host):
        host.set_mock_response(prov, fam, _ok_response("cheap"))
    r = client.post("/v1/chat/completions", json={
        "model": "profile:cheap_explore",
        "messages": [{"role": "user", "content": "hi"}],
    })
    assert r.status_code == 200
    assert r.json()["choices"][0]["message"]["content"] == "cheap"


def test_family_prefix_filters_to_family(client, host):
    # Only mock the deepseek family — if shim correctly constrains to that
    # family, requests succeed; if it ignores the filter and picks something
    # else, they fail.
    for prov, fam in _all_pairs(host):
        if fam == "deepseek-v3":
            host.set_mock_response(prov, fam, _ok_response("deepseek"))
    r = client.post("/v1/chat/completions", json={
        "model": "family:deepseek-v3",
        "messages": [{"role": "user", "content": "hi"}],
    })
    assert r.status_code == 200
    assert r.json()["x_router"]["model_family"] == "deepseek-v3"


def test_pin_prefix_short_circuits_to_single_pair(client, host):
    host.set_mock_response("comput3", "hermes-3-405b", _ok_response("pinned"))
    r = client.post("/v1/chat/completions", json={
        "model": "pin:comput3/hermes-3-405b",
        "messages": [{"role": "user", "content": "hi"}],
    })
    assert r.status_code == 200
    body = r.json()
    assert body["x_router"]["provider"] == "comput3"
    assert body["x_router"]["model_family"] == "hermes-3-405b"


def test_unknown_model_string_falls_back_to_default(client, host):
    for prov, fam in _all_pairs(host):
        host.set_mock_response(prov, fam, _ok_response("fallback"))
    r = client.post("/v1/chat/completions", json={
        "model": "totally-made-up-model-name",
        "messages": [{"role": "user", "content": "hi"}],
    })
    assert r.status_code == 200
    assert r.json()["choices"][0]["message"]["content"] == "fallback"


# ---- response shape ----------------------------------------------------

def test_response_shape_is_openai_compatible(client, host):
    for prov, fam in _all_pairs(host):
        host.set_mock_response(prov, fam, _ok_response("hi"))
    r = client.post("/v1/chat/completions", json={
        "model": "", "messages": [{"role": "user", "content": "hi"}],
    })
    body = r.json()
    assert body["object"] == "chat.completion"
    assert body["id"].startswith("chatcmpl-")
    assert isinstance(body["created"], int)
    assert body["choices"][0]["index"] == 0
    assert body["choices"][0]["finish_reason"] == "stop"
    assert body["choices"][0]["message"]["role"] == "assistant"
    assert body["usage"] == {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10}
    # x_router metadata is non-standard but useful
    assert body["x_router"]["served_model_id"] is not None


# ---- failure / fallback paths ------------------------------------------

def test_streaming_returns_400(client):
    r = client.post("/v1/chat/completions", json={
        "model": "", "messages": [{"role": "user", "content": "hi"}], "stream": True,
    })
    assert r.status_code == 400
    assert r.json()["error"]["type"] == "invalid_request_error"


def test_all_candidates_fail_returns_5xx(client, host):
    # No mocks set => _default_mock_call returns no_mock_set for every call.
    # Router exhausts candidates → exhausted: <last_error_kind>.
    r = client.post("/v1/chat/completions", json={
        "model": "", "messages": [{"role": "user", "content": "hi"}],
    })
    assert r.status_code >= 500
    err = r.json()["error"]
    assert err["type"] == "router_error"
    assert "exhausted" in err["code"] or "no_candidates" in err["code"]


def test_pin_to_missing_pair_returns_5xx(client):
    r = client.post("/v1/chat/completions", json={
        "model": "pin:nope/nada",
        "messages": [{"role": "user", "content": "hi"}],
    })
    assert r.status_code >= 500
    assert r.json()["error"]["type"] == "router_error"


def test_fallback_on_first_candidate_failure(client, host):
    # Make every candidate fail except a known-second-tier one to force the
    # router to walk past failures into a working candidate.
    pairs = _all_pairs(host)
    assert len(pairs) >= 2
    target_prov, target_fam = pairs[-1]
    for prov, fam in pairs:
        if (prov, fam) == (target_prov, target_fam):
            host.set_mock_response(prov, fam, _ok_response("fallback worked"))
        else:
            host.set_mock_response(prov, fam, _err_response("server_error", 500))
    r = client.post("/v1/chat/completions", json={
        "model": "", "messages": [{"role": "user", "content": "hi"}],
    })
    assert r.status_code == 200
    body = r.json()
    assert body["choices"][0]["message"]["content"] == "fallback worked"
    assert body["x_router"]["provider"] == target_prov


# ---- helpers -----------------------------------------------------------

def _all_pairs(host) -> list[tuple[str, str]]:
    """Every (provider_id, model_family) pair in the loaded catalog."""
    info = host.info()
    pairs: list[tuple[str, str]] = []
    # info doesn't expose pairs directly; use rank() on default to enumerate.
    ranked, _ = host.rank({"prompt": "x", "profile": "default"})
    seen = set()
    for r in ranked:
        c = r["candidate"]
        key = (c["provider_id"], c["model_family"])
        if key not in seen:
            seen.add(key)
            pairs.append(key)
    return pairs
