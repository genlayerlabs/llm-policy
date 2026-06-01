"""
Host-side credential layer: provider `auth` descriptor → request headers.
The router carries the `auth` blob opaquely; all auth semantics live here.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "hosts" / "python"))

from llm_router_host import _resolve_auth_headers, _prepare_openai_call  # noqa: E402


def _env(mapping):
    return lambda k: mapping.get(k)


# ---- auth kinds --------------------------------------------------------

def test_bare_auth_env_is_treated_as_bearer():
    headers, err = _resolve_auth_headers(
        {"auth_env": "MY_KEY"}, _env({"MY_KEY": "sk-123"}))
    assert err is None
    assert headers == {"Authorization": "Bearer sk-123"}


def test_bearer_missing_env_is_auth_error():
    headers, err = _resolve_auth_headers(
        {"auth_env": "MY_KEY"}, _env({}))
    assert headers is None
    assert err["error_kind"] == "auth_error"


def test_kind_none_sends_no_authorization_header():
    headers, err = _resolve_auth_headers(
        {"auth": {"kind": "none"}, "base_url": "http://localhost:8377/v1"}, _env({}))
    assert err is None
    assert headers == {}, "no Authorization header for kind=none"


def test_kind_bearer_explicit_env():
    headers, err = _resolve_auth_headers(
        {"auth": {"kind": "bearer", "env": "HEURIST"}}, _env({"HEURIST": "tok"}))
    assert err is None
    assert headers["Authorization"] == "Bearer tok"


def test_kind_oauth_uses_token_provider():
    headers, err = _resolve_auth_headers(
        {"auth": {"kind": "oauth", "provider": "codex"}},
        _env({}),
        token_providers={"codex": lambda: "oauth-token"},
    )
    assert err is None
    assert headers["Authorization"] == "Bearer oauth-token"


def test_kind_oauth_without_provider_is_error():
    headers, err = _resolve_auth_headers(
        {"auth": {"kind": "oauth", "provider": "codex"}}, _env({}))
    assert headers is None
    assert err["error_kind"] == "auth_error"


def test_unknown_kind_is_error():
    headers, err = _resolve_auth_headers({"auth": {"kind": "magic"}}, _env({}))
    assert headers is None
    assert err["error_kind"] == "auth_error"


# ---- request prep ------------------------------------------------------

def test_prepare_builds_url_body_and_headers():
    prep, err = _prepare_openai_call(
        {
            "served_model_id": "minimax/minimax-m2.7",
            "base_url": "https://openrouter.ai/api/v1/",
            "messages": [{"role": "user", "content": "hi"}],
            "tools": [{"type": "function"}],
            "temperature": 0.5,
            "auth": {"kind": "none"},
        },
        _env({}), extra={}, timeout_s=30.0,
    )
    assert err is None
    url, body, headers, timeout = prep
    assert url == "https://openrouter.ai/api/v1/chat/completions"
    assert body["model"] == "minimax/minimax-m2.7"
    assert body["tools"] == [{"type": "function"}]
    assert body["temperature"] == 0.5
    assert headers["Content-Type"] == "application/json"
    assert "Authorization" not in headers
    assert timeout == 30.0


def test_prepare_propagates_auth_error():
    prep, err = _prepare_openai_call(
        {"served_model_id": "m", "base_url": "http://x", "auth_env": "UNSET"},
        _env({}), extra={}, timeout_s=10.0,
    )
    assert prep is None
    assert err["error_kind"] == "auth_error"
