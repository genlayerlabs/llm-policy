"""
Entrypoint for the llm-router HTTP shim.

    python -m hosts.python_shim \
        --router   router.lua \
        --config   config.lua \
        --metrics  metrics.lua \
        --default-profile default \
        --host 127.0.0.1 --port 8080

Provider auth lives in the process environment (the router resolves
`auth_env` per provider via `host.env`). Clients hitting the shim do NOT
need provider API keys — they only need to reach the shim's URL.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "hosts" / "python"))

from llm_router_host import (  # noqa: E402
    LLMRouterHost,
    make_async_call_provider,
    make_api_kind_dispatcher,
)


def main() -> None:
    p = argparse.ArgumentParser(prog="python -m hosts.python_shim")
    p.add_argument("--router", type=Path, default=ROOT / "router.lua",
                   help="path to router.lua (default: repo root)")
    p.add_argument("--config", type=Path, required=True,
                   help="path to config.lua")
    p.add_argument("--metrics", type=Path, default=None,
                   help="optional path to metrics.lua")
    p.add_argument("--default-profile", default="default",
                   help="profile used when `model` field doesn't match a prefix")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--timeout-s", type=float, default=30.0,
                   help="upstream provider call timeout in seconds")
    p.add_argument("--codex-auth", type=Path, default=None,
                   help="path to Codex auth.json for api_kind=openai_codex "
                        "(default: ~/.codex/auth.json). Enables the ChatGPT "
                        "subscription provider — unofficial, ToS-risky.")
    args = p.parse_args()

    # api_kind=openai_codex is served by a dedicated backend (Codex Responses
    # endpoint + codex login token); everything else uses the OpenAI-compatible
    # backend. The Codex backend reads auth.json lazily on first use.
    from codex_auth import CodexAuth          # noqa: E402
    from codex_backend import make_codex_async_call_provider  # noqa: E402

    codex_auth = CodexAuth(args.codex_auth)
    call_async = make_api_kind_dispatcher(
        default=make_async_call_provider(timeout_s=args.timeout_s),
        handlers={"openai_codex": make_codex_async_call_provider(codex_auth)},
    )

    host = LLMRouterHost(
        router_path=args.router,
        config_path=args.config,
        metrics_path=args.metrics,
        call_provider_async=call_async,
    )
    host.init()

    from .shim import create_app  # local import: keeps argparse errors fast
    app = create_app(host, default_profile=args.default_profile)

    import uvicorn
    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
