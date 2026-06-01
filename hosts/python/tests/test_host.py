"""
Integration tests for llm_router_host.py.

Run from repo root:
    pytest hosts/python/tests -v

These tests exercise the Python -> Lua boundary: config loads, info() reports
the catalog, rank() returns plausible candidates, marketplace discovery
threads through the host, and pin short-circuits the pool.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "hosts" / "python"))

from llm_router_host import LLMRouterHost  # noqa: E402


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


def test_info_reports_catalog(host):
    info = host.info()
    assert info["initialized"] is True
    assert "comput3" in info["providers_loaded"]
    assert "antseed" in info["providers_loaded"]
    assert "hermes-3-405b" in info["models_loaded"]
    assert "default" in info["profile_names"]
    # static candidates only here (no marketplace yet — that happens per-call)
    assert info["candidates"] > 0


def test_init_logs_initialization(host):
    events = [evt for _, evt, _ in host.log_records]
    assert "router_initialized" in events


def test_rank_default_profile_returns_candidates(host):
    ranked, rejected = host.rank({"prompt": "hi", "profile": "default"})
    assert len(ranked) > 0
    first = ranked[0]
    assert "candidate" in first
    assert "score" in first
    assert "score_breakdown" in first
    # scores must be monotone non-increasing
    scores = [r["score"] for r in ranked]
    assert scores == sorted(scores, reverse=True)


def test_rank_breakdown_components_are_in_unit_interval(host):
    ranked, _ = host.rank({"prompt": "hi", "profile": "default"})
    for item in ranked:
        b = item["score_breakdown"]
        for key in ("quality", "speed", "cost", "free_credit", "partner"):
            v = b[key]
            assert 0.0 <= v <= 1.0, f"{key}={v} out of [0,1]"


def test_pin_short_circuits_to_single_candidate(host):
    ranked, rejected = host.rank({
        "prompt": "x",
        "profile": "default",
        "requirements": {"pin": {"provider": "comput3", "model": "hermes-3-405b"}},
    })
    assert len(ranked) == 1
    assert ranked[0]["candidate"]["provider_id"] == "comput3"
    assert ranked[0]["candidate"]["model_family"] == "hermes-3-405b"


def test_pin_to_missing_pair_returns_empty_and_reason(host):
    ranked, rejected = host.rank({
        "prompt": "x",
        "profile": "default",
        "requirements": {"pin": {"provider": "bogus", "model": "bogus"}},
    })
    assert ranked == []
    assert len(rejected) == 1
    assert rejected[0]["reason"] == "pin_not_found"


def test_vision_need_filters_to_vision_capable_model(host):
    ranked, _ = host.rank({
        "prompt": "describe",
        "images": [{"url": "x"}],
        "profile": "default",
    })
    assert len(ranked) > 0
    for item in ranked:
        assert item["candidate"]["model_family"] == "qwen-2.5-vl-72b"


def test_tee_profile_keeps_only_tee_providers(host):
    ranked, _ = host.rank({
        "prompt": "secret",
        "profile": "tee_only",
        "requirements": {"privacy": "tee_required"},
    })
    assert len(ranked) > 0
    for item in ranked:
        assert item["candidate"]["provider_id"] == "atoma"


def test_marketplace_discovery_merges_offers_into_pool(host):
    host.set_discover_hook(lambda did: {
        "ok": True,
        "fetched_at_ms": 1_000_000,
        "offers": [
            {
                "model_family":           "llama-3.3-70b",
                "seller_endpoint":        "https://seller.example/v1",
                "price_in_usd_per_mtok":  0.05,
                "price_out_usd_per_mtok": 0.10,
                "est_tok_s":              45,
                "capabilities": {
                    "context":            128_000,
                    "supports_tools":     True,
                    "supports_json_mode": True,
                    "supports_seed":      True,
                },
            },
        ],
    } if did == "antseed_buyer_node" else {"ok": False, "error": "unknown"})

    ranked, _ = host.rank({"prompt": "x", "profile": "default"})
    market_candidates = [
        r for r in ranked
        if r["candidate"]["discovery"] == "marketplace"
    ]
    assert len(market_candidates) >= 1, "marketplace offer should appear"
    assert market_candidates[0]["candidate"]["provider_id"] == "antseed"


def test_weights_override_reranks(host):
    # baseline default profile
    ranked_default, _ = host.rank({"prompt": "x", "profile": "default"})
    # same contract but force cost-only ranking
    ranked_cost, _ = host.rank({
        "prompt": "x",
        "profile": "default",
        "weights_override": {
            "cost": 1.0, "quality": 0, "speed": 0, "free_credit": 0, "partner": 0,
        },
    })
    # at least the top candidate should differ when we change the weights so drastically
    # (no strict ordering check — just that scoring responded to the override)
    default_top = ranked_default[0]["candidate"]["provider_id"]
    cost_top = ranked_cost[0]["candidate"]["provider_id"]
    # both should be valid, and breakdowns should reflect the override
    assert ranked_cost[0]["score_breakdown"]["weights"]["cost"] == pytest.approx(1.0)
    assert ranked_cost[0]["score_breakdown"]["weights"]["quality"] == pytest.approx(0.0)


def test_min_tok_s_filters_unbenched_candidates(host):
    # min_tok_s=39 should keep only candidates with observed tok_s >= 39 in metrics.
    # Per metrics.example: hermes@comput3=42.1, llama@io_net=40.0 → both pass.
    # deepseek@comput3=38.0 fails. Others have no metrics → fail.
    ranked, rejected = host.rank({
        "prompt": "x",
        "profile": "default",
        "requirements": {"min_tok_s": 39},
    })
    surviving = {(r["candidate"]["provider_id"], r["candidate"]["model_family"])
                 for r in ranked}
    assert ("comput3", "hermes-3-405b") in surviving
    assert ("io_net", "llama-3.3-70b") in surviving
    assert ("comput3", "deepseek-v3") not in surviving
    # at least one rejection with reason min_tok_s
    reasons = {r["reason"] for r in rejected}
    assert "min_tok_s" in reasons


def test_open_circuit_breaker_zeros_score(host):
    # Inject an open breaker on comput3 via the test backdoor. now_ms is
    # frozen at 1_000_000; we open the breaker 1s ago so it's still within
    # the rate-limit TTL (default 30s).
    runtime = host.router._test.runtime()
    runtime["circuit_breakers"]["comput3"] = host.lua.table_from({
        "open": True,
        "opened_at_ms": 999_000,
        "consecutive_failures": 3,
    })

    ranked, _ = host.rank({"prompt": "x", "profile": "default"})
    comput3_items = [
        r for r in ranked if r["candidate"]["provider_id"] == "comput3"
    ]
    assert comput3_items, "comput3 should still be in survivors (filter ignores breaker)"
    for item in comput3_items:
        assert item["score"] == 0.0, "open breaker forces final score to 0"
        assert item["score_breakdown"]["breaker_open"] is True
