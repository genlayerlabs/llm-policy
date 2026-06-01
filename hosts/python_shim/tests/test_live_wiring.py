"""
End-to-end wiring against the real config.live.lua catalog: the async shim +
api_kind dispatcher route the openai_codex provider to the Codex backend and
everything else to the OpenAI-compatible backend. Mirrors __main__'s wiring,
with both backends faked so no network is touched.
"""
from __future__ import annotations

import sys
from pathlib import Path

from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "hosts" / "python"))

from llm_router_host import LLMRouterHost, make_api_kind_dispatcher  # noqa: E402
from hosts.python_shim.shim import create_app  # noqa: E402


def _build_client(default_handler, codex_handler):
    host = LLMRouterHost(
        router_path=ROOT / "router.lua",
        config_path=Path(__file__).resolve().parents[1] / "config.live.lua",
        call_provider_async=make_api_kind_dispatcher(
            default=default_handler,
            handlers={"openai_codex": codex_handler},
        ),
        now_ms=lambda: 1,
    )
    host.init()
    return TestClient(create_app(host, default_profile="agent"))


def test_pin_routes_codex_through_dispatcher():
    async def default(req):
        return {"ok": False, "error_kind": "server_error"}

    async def codex(req):
        assert req["api_kind"] == "openai_codex"
        assert req["served_model_id"] == "gpt-5.5-codex"
        return {"ok": True, "latency_ms": 5,
                "response": {"text": "from-codex", "finish_reason": "stop"}}

    client = _build_client(default, codex)
    r = client.post("/v1/chat/completions", json={
        "model": "pin:openai/gpt-5.5-codex",
        "messages": [{"role": "user", "content": "hi"}],
    })
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["choices"][0]["message"]["content"] == "from-codex"
    assert body["x_router"]["provider"] == "openai"


def test_agent_profile_cascades_to_openai_compatible_backend():
    # gpt-5.5-codex is the agent profile's top pick; make the codex backend fail
    # so the router cascades to an openai_compatible partner served by `default`.
    async def default(req):
        return {"ok": True, "latency_ms": 5,
                "response": {"text": f"served-by-{req['provider_id']}", "finish_reason": "stop"}}

    async def codex(req):
        return {"ok": False, "error_kind": "server_error"}

    client = _build_client(default, codex)
    r = client.post("/v1/chat/completions", json={
        "model": "profile:agent",
        "messages": [{"role": "user", "content": "hi"}],
    })
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["choices"][0]["message"]["content"].startswith("served-by-")
    assert body["x_router"]["provider"] != "openai", "cascaded off the failing codex provider"
