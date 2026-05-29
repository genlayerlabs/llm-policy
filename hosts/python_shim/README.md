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

Concurrency note: lupa serializes Lua execution on a single `LuaRuntime`.
FastAPI runs sync handlers in a thread pool, but the Lua side is
one-at-a-time. Fine for one or a handful of concurrent clients; not the
right tool for hundreds or thousands of concurrent callers. For that
workload, a luerl-based (Erlang) host is the planned answer.

## Running

```bash
# from repo root
nix-shell -p 'python3.withPackages(ps: with ps; [lupa httpx fastapi uvicorn pydantic])' \
    --run 'python -m hosts.python_shim \
        --config config.live.lua \
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
from DESIGN.md §11's "per-process state" assumption, which holds for
the embed-in-app host but not for the shim.

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
