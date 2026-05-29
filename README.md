# llm-router

A small, embeddable LLM router. Given a *contract* describing what you need from an LLM call, it picks the best `(provider, model)` from a declarative catalog, dispatches via a host-provided HTTP function, classifies the response, and falls back to the next candidate on failure.

- **Pure Lua library** (`router.lua`). No HTTP, no auth, no I/O. The embedding host provides those.
- **Config is a Lua table** (`config.lua`). Catalog of providers, models, profiles, retry policy.
- **Two execution modes.** Synchronous (Python scripts, plain hosts) and cooperative async (wasmtime, GenVM).
- **No CLI binary.** Two optional Python tools for schema validation and benchmarking.

Designed to be embedded by Python (lupa), Rust (mlua, e.g. inside GenVM), Elixir (luerl), or any other host with a Lua VM.

## Status

Pre-release. See [`DESIGN.md`](./DESIGN.md) for the current design.

## Why

Most projects that talk to LLMs end up reimplementing the same routing, fallback, and retry logic. This library extracts that logic into a single artifact that any Lua-capable host can embed, such as the GenVM.

## Quick taste

```lua
-- contract
local result = router.execute({
  prompt       = "Classify this feedback as positive / negative / neutral: ...",
  requirements = { needs = { "json_mode" }, min_context = 4000 },
  profile      = "cheap_explore",
  trace        = true,
})

if result.ok then
  print(result.response)        -- raw provider response body
else
  print(result.error.kind, result.error.detail)
end

for _, attempt in ipairs(result.trace) do
  print(attempt.provider, attempt.model, attempt.outcome, attempt.duration_ms)
end
```

## Repo layout

```
router.lua                 -- the library
config.example.lua         -- example catalog + profiles
metrics.example.lua        -- example bench output
tools/
  validate.py              -- schema check
  bench.py                 -- regenerate metrics.lua
hosts/
  python/                  -- reference host (lupa + httpx)
  rust/                    -- mlua skeleton for GenVM-style embedding
tests/
docs/
  PROVIDERS.md             -- partner catalog notes
  PRIVATE-DEPLOYMENT.md    -- privacy-conscious usage notes
```
