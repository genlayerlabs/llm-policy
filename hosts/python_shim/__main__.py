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

from llm_router_host import LLMRouterHost, make_http_call_provider  # noqa: E402


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
    args = p.parse_args()

    host = LLMRouterHost(
        router_path=args.router,
        config_path=args.config,
        metrics_path=args.metrics,
        call_provider=make_http_call_provider(timeout_s=args.timeout_s),
    )
    host.init()

    from .shim import create_app  # local import: keeps argparse errors fast
    app = create_app(host, default_profile=args.default_profile)

    import uvicorn
    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
