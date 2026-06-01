# python_shim — OpenAI-compatible HTTP façade for llm-router

A small FastAPI server that loads `router.lua` + `config.lua` and exposes
`POST /v1/chat/completions`. Any OpenAI-compatible client (the OpenAI
SDK, `curl`, agent runtimes, anything that speaks chat-completions) can
point at the shim and inherit the router's provider selection, fallback,
and retry logic without knowing it exists.

```
┌────────────────────┐    ┌──────────────────────────────┐    ┌──────────┐
│ any OpenAI-        │POST│  python_shim                 │HTTPS│ upstream │
│ compatible client  ├────▶  - FastAPI /v1/chat/         ├─────▶ provider │
│                    │    │    completions               │     │          │
└────────────────────┘    │  - lupa(router.lua,config.lua)│     └──────────┘
                          └──────────────────────────────┘
```

## When to use this vs the embed-in-app host

| Host                        | Use when                                                  |
|-----------------------------|-----------------------------------------------------------|
| `hosts/python/` (lib)       | Python apps that import the router as a library           |
| `hosts/python_shim/` (this) | Any OpenAI-compatible client that hits an HTTP endpoint   |

Concurrency: the endpoint is `async` and drives `router.execute_step`
(yield-on-IO). The single `LuaRuntime` is touched only for the microseconds of
each routing step; the slow upstream HTTP is `await`-ed off the Lua lock, so one
process overlaps many in-flight requests on one event loop. Because asyncio is
single-threaded, concurrent requests never run Lua simultaneously and the shared
router state (breakers, EMA) stays race-free. Scale further with multiple
processes/replicas behind a load balancer — at which point shared state
(circuit breakers, credits, the Codex OAuth token) must be externalized; see
[`docs/POLICY_DESIGN.md`](../../docs/POLICY_DESIGN.md) §9.

## Running

```bash
# from repo root
nix-shell -p 'python3.withPackages(ps: with ps; [lupa httpx fastapi uvicorn pydantic])' \
    --run 'python -m hosts.python_shim \
        --config hosts/python_shim/config.live.lua \
        --metrics metrics.example.lua \
        --default-profile default \
        --host 127.0.0.1 --port 8080'
```

Provider auth keys live in the process environment of the shim (the router
resolves each provider's `auth_env` via `host.env`). Clients hitting the
shim do **not** carry provider keys.

Flags:

- `--router PATH`     `router.lua` (default: repo root)
- `--config PATH`     **required**; your `config.lua`
- `--metrics PATH`    optional `metrics.lua`
- `--default-profile NAME`   profile used when `model` doesn't match a prefix (default `default`)
- `--host` / `--port` bind address (default `127.0.0.1:8080`)
- `--timeout-s N`     upstream provider timeout in seconds (default 30)
- `--codex-auth PATH` Codex `auth.json` for `api_kind=openai_codex` providers
  (default `~/.codex/auth.json`). Enables the ChatGPT-subscription path —
  unofficial / ToS-risky; see `docs/OPENAI-CODEX.md`.

## `model` field convention

The shim interprets the OpenAI `model` field via explicit prefixes — no
content sniffing.

| Client sends                       | Shim does                                                   |
|------------------------------------|-------------------------------------------------------------|
| `model: ""` (empty)                | use `--default-profile`                                     |
| `model: "profile:cheap_explore"`   | `contract.profile = "cheap_explore"`                        |
| `model: "family:deepseek-v3"`      | default profile + `requirements.model_family = "deepseek-v3"` |
| `model: "pin:<provider>/<family>"` | default profile + `requirements.pin = {provider, model}`    |
| `model: "anything-else"`           | default profile (no warning today; bare strings reserved)   |

Unprefixed strings deliberately do nothing clever — they degrade to the
default profile rather than guessing. Add a prefix to express intent.

## Endpoints

- `POST /v1/chat/completions` — OpenAI-compatible. Streaming (`stream: true`) returns 400.
- `GET /v1/models` — lists `profile:*` and `family:*` ids the shim recognizes.
- `GET /healthz` — `{ ok, initialized }`.

The 200 response body adds one non-standard key, `x_router`:

```json
{
  "id": "chatcmpl-…",
  "object": "chat.completion",
  "choices": [{ "message": { "role": "assistant", "content": "…" }, "finish_reason": "stop", "index": 0 }],
  "usage":  { "prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10 },
  "x_router": { "provider": "<provider-id>", "model_family": "<family>", "served_model_id": "<upstream-id>" }
}
```

OpenAI SDKs ignore unknown keys; `x_router` is just for debugging which
candidate served the call.

## Error mapping

When the router exhausts all candidates, the shim returns OpenAI-shaped
JSON with HTTP status derived from the last error kind:

| Last error kind                    | HTTP |
|------------------------------------|------|
| `no_candidates`                    | 503  |
| `auth_error`                       | 401  |
| `rate_limit`                       | 429  |
| `bad_request` / `context_overflow` | 400  |
| anything else                      | 502  |
| router uninitialized               | 500  |

## State sharing

A single shim instance owns one router state (circuit breakers, EMA
latencies, discovery cache). All clients of that shim share it: a
provider cooldown discovered by one request applies to every subsequent
request, no matter which client made it. This is usually what you want
when one machine fronts several clients; it's the operational shift away
from the per-process-state assumption, which holds for the embed-in-app host
but not for the shim.

If you need isolated state per client, run several shim instances on
different ports and route clients to the one whose policy you want.

## Tests

```bash
nix-shell -p 'python3.withPackages(ps: with ps; [lupa httpx fastapi uvicorn pydantic pytest])' \
    --run 'python -m pytest hosts/python_shim/tests -v'
```

The tests boot a real `LLMRouterHost` with mocked provider responses
(`set_mock_response`). Only the outbound HTTP to upstream providers is
mocked; the router and Lua/Python boundary are exercised end-to-end.
