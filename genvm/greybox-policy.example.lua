-- greybox-policy.example.lua
--
-- The genlayer-node `genvm-llm-greybox.lua` behavior, expressed as an llm_policy
-- *sentence*. This is the expressive part; the GenVM dispatch host stays a thin
-- shim around it (resolve the chain from meta.greybox / hot-reload JSON, pick
-- text vs image by prompt modality, inject the per-call OsRng seed, call the
-- provider). See ../docs/GENVM-LLM-POLICY.md.
--
-- Faithful mapping to the production script:
--   meta.greybox priority chains (text/image)  -> R.chain(chain)
--   select_providers_for (modality/caps)        -> F.requirements()
--   tryChain pcall fall-through on overload      -> the `cascade` sequence
--   lib.rs.filter_text(NFKC/RmZeroWidth/NormWS)  -> M.filter_text{...}
--   per-call OsRng seed (per-node variation)     -> host/runtime (NOT policy)

local F      = require("llm_policy.filter")
local R      = require("llm_policy.rank")
local M      = require("llm_policy.mutate")
local Policy = require("llm_policy.policy")

-- "Try the chain in order; fall through on overload/transient; stop on auth/bad
-- request." Mirrors tryChain's pcall loop + overloaded_statuses handling.
local cascade = {
    rate_limit        = { action = "next_candidate" },
    timeout           = { action = "next_candidate" },
    server_error      = { action = "next_candidate" },
    model_unavailable = { action = "next_candidate" },
    content_filter    = { action = "next_candidate" },
    network_error     = { action = "next_candidate" },
    auth_error        = { action = "disable_provider" },
    bad_request       = { action = "abort" },
    context_overflow  = { action = "abort" },
    unknown           = { action = "next_candidate" },
}

-- chain: ordered list { {provider=, model=}, ... } resolved by the host from
-- meta.greybox or /tmp/greybox-config.json (text or image, per modality).
-- mut_seed: optional — when set, harden divergence with seeded prompt/param
-- mutation on top of the (organic) per-operator catalog differences. The
-- per-call LLM sampling seed stays a runtime/OsRng concern, not policy.
local function greybox(chain, opts)
    opts = opts or {}
    local mut = M.filter_text{ "NFKC", "RmZeroWidth", "NormalizeWS" }
    if opts.jitter then
        mut = M.pipe{ mut, M.jitter{ temperature = opts.jitter } }
    end
    return Policy.new{
        filter   = F.requirements(),   -- modality/caps gate (= select_providers_for)
        select   = R.chain(chain),     -- deterministic priority order
        mutate   = mut,
        sequence = cascade,
    }
end

return greybox
