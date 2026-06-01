# Providers

Operational notes for the provider catalog in `../config.live.lua`. The router
itself is auth-agnostic: each provider declares how it authenticates and the
**host** resolves it (see `_resolve_auth_headers` in
`hosts/python/llm_router_host.py`). Three auth kinds:

| `auth`                                   | Header sent                | Used by              |
|------------------------------------------|----------------------------|----------------------|
| `auth_env = "X"` (or `{kind="bearer"}`)  | `Authorization: Bearer $X` | heurist, io_net, openrouter |
| `{ kind = "none" }`                      | *(none)*                   | antseed              |
| `{ kind = "oauth", provider = "codex" }` | `Authorization: Bearer <refreshed token>` | openai (codex) |

## Bearer providers (heurist, io.net, openrouter)

Standard OpenAI-compatible gateways. Put the key in the shim's process
environment under the provider's `auth_env` name. Clients hitting the shim do
**not** carry these keys.

## AntSeed (local node, no auth)

AntSeed is a decentralized meta-router: a local node speaks OpenAI Chat
Completions on `http://localhost:8377/v1/chat/completions` with **no
Authorization header** and routes each request to network peers by
price/latency/reputation. Because it picks the downstream provider itself and
doesn't report which, we model it as a **fallback tier**, not a quality-rankable
partner.

### Running the node (runtime dependency — not vendored)

No fork, no submodule. The node is an external daemon you run as a sidecar:

```bash
npm install -g @antseed/cli
antseed seller setup        # generates the node identity (secp256k1 key)
# start the node so localhost:8377 is live (see antseed docs/install)
```

- **Identity + wallet:** the node needs a secp256k1 identity and a **funded
  wallet** to pay peers for inference. Staking is only required to *sell*; to
  *buy* (our case) you only need a funded buyer identity.
- **Per replica:** if you scale the shim horizontally, each replica needs a
  reachable AntSeed node. Either run a node sidecar per replica (each with its
  own funded identity) or point them at one shared AntSeed instance (then it is
  no longer `localhost`). Decide this when you add replicas.

The `model` field we send (`deepseek-v3.1`, etc.) is forwarded verbatim; AntSeed
translates protocols and picks the peer.

## OpenAI via ChatGPT subscription (Codex proxy)

See [`docs/OPENAI-CODEX.md`](./OPENAI-CODEX.md). **Unofficial and ToS-risky** —
the Apps SDK OAuth does not grant inference on a subscription; only the Codex
login + local proxy path works, and OpenAI may close it (as Anthropic and Google
closed their equivalents in 2026). Use a normal OpenAI API key
(`auth_env = "OPENAI_API_KEY"`, `api_kind = "openai_compatible"`) if you want a
supported path instead.
