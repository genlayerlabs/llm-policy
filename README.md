# llm_policy

A small, embeddable **policy algebra for LLM provider selection**, in pure Lua.
You describe *what you need from an LLM call* (a contract); a **policy** —
composed from four verbs over a declarative catalog — decides which
`(provider, model)` to call, with what request, and what to do on failure. The
embedding host performs the I/O.

The four verbs (see [`docs/POLICY_DESIGN.md`](./docs/POLICY_DESIGN.md)):

- **`filter`** — which candidates are eligible (pure predicates).
- **`rank` / `select`** — order the eligible candidates (pure scorers + selector).
- **`mutate`** — transform the outgoing request for a chosen candidate.
- **`sequence`** — what to do when an attempt fails (declarative, fixed vocabulary).

Two consumers, one language:

- **Off-chain (subzero ecosystem)** — a policy that *converges* on the best
  available provider: resilience + cost optimization for an agent fleet.
- **On-chain (GenVM greyboxing)** — each validator writes its own policy; the
  ease of writing 1000 *different* policies, over a well-defined provider object,
  **is** the security property. See [`docs/GENVM-LLM-POLICY.md`](./docs/GENVM-LLM-POLICY.md).

## Properties

- **Pure Lua, no I/O, no credentials, no globals.** The verbs are pure functions
  of an explicit `ctx`; the engine (the impure orchestrator) snapshots runtime
  state into `ctx` and performs no I/O itself. Embeddable in lupa (Python), mlua
  (Rust / GenVM), luerl (Elixir).
- **Two execution modes.** Synchronous (`execute`) and cooperative async
  (`execute_step`, yield-on-IO) so one host process overlaps many in-flight calls.
- **Host-resolved auth.** Providers declare `auth = {kind="none"|"bearer"|"oauth"}`;
  the host turns that into headers. The core never sees a key.
- **Same decision, two runtimes.** Given the same `(policy, catalog, ctx, seed)`,
  selection is identical under mlua and lupa — the defining invariant.

## Package

The core is the `llm_policy` package; `router.lua` is a compatibility shim
(`return require("llm_policy")`) so existing embedders keep working.

```lua
local llm_policy = require("llm_policy")   -- or dofile("router.lua")
llm_policy.init(config, metrics)
local result = llm_policy.execute({
  prompt       = "Classify this feedback as positive / negative / neutral: ...",
  requirements = { needs = { "json_mode" }, min_context = 4000 },
  profile      = "cheap_explore",
})
if result.ok then print(result.response.text) else print(result.error) end
```

## Repo layout

This repo **is** the core (sealed). `hosts/` are example host implementations
that will be extracted to their own repos; `genvm/` is the on-chain adapter
overlay. The core never references a host — hosts import the core. Deployment
data (live catalogs, provider docs, credentials) lives with the hosts.

```
# ── core (this repo) ──
llm_policy.lua             -- package entry (init / execute / execute_step / rank / …)
llm_policy/
  filter.lua  rank.lua  mutate.lua  sequence.lua  policy.lua   -- the algebra
  candidate.lua  util.lua                                      -- object + helpers
router.lua                 -- compat shim: return require("llm_policy")
config.example.lua         -- example catalog + profiles (schema illustration)
metrics.example.lua        -- example metrics seed
docs/
  POLICY_DESIGN.md         -- the candidate object + the policy algebra
  GENVM-LLM-POLICY.md      -- using llm_policy as a node's greyboxing algebra
tests/                     -- Lua unit tests (run_lua.lua, unit/, smoke_rank.lua)

# ── example host implementations (departing) ──
hosts/
  python/                  -- embed-in-app host (lupa + httpx); tests/
  python_shim/             -- OpenAI-compatible FastAPI shim (async)
                           --   config.live.lua, docs/{PROVIDERS,OPENAI-CODEX}.md,
                           --   live_smoke.py, tests/
genvm/                     -- on-chain greybox adapter overlay (dispatch.lua + integrate.sh); tests/
```

## HTTP shim (use from any OpenAI-compatible client)

[`hosts/python_shim/`](./hosts/python_shim/) is an async FastAPI façade exposing
`POST /v1/chat/completions`. Any OpenAI-compatible client points at it and
inherits provider selection, fallback and retry without knowing the core exists.
Routing lives **server-side**: the client's `model` field is ignored unless it
carries an explicit `profile:` / `family:` / `pin:` prefix.

Example — [subzeroclaw](../../personal/subzeroclaw) (a C agent loop that POSTs
chat-completions via curl):

```ini
# ~/.subzeroclaw/config
endpoint = "http://127.0.0.1:8080/v1/chat/completions"
api_key  = "dummy"          # subzeroclaw requires non-empty; the shim ignores client auth
model    = "profile:agent"  # the shim's `agent` profile decides the real (provider, model)
```

Start the shim with the provider keys in its environment:

```bash
python -m hosts.python_shim --config hosts/python_shim/config.live.lua \
    --default-profile agent --host 127.0.0.1 --port 8080
```

See [`hosts/python_shim/README.md`](./hosts/python_shim/README.md) for the model
field convention and [`hosts/python_shim/docs/PROVIDERS.md`](./hosts/python_shim/docs/PROVIDERS.md)
for per-provider auth and the AntSeed node / Codex setup.
