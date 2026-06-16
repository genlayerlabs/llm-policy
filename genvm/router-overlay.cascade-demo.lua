-- router-overlay.cascade-demo.lua — forces heurist > openrouter so the
-- cascade is observable: heurist times out (unreachable from this network),
-- router falls through to the openrouter-backed `dev` backend.

return {
    providers = {
        heurist = { tier = "partner" },
        dev     = { tier = "fallback" },
    },
    models = {
        ["meta-llama/llama-3.3-70b-instruct"] = { static_quality_hint = 0.85 },
        ["openrouter/auto"]                   = { static_quality_hint = 0.70 },
    },
    profiles = {
        default = {
            -- (sigma-pol/v2) `weights`/composite atoms removed; score on real
            -- fields. Tier preference is now a FILTER concern (min_tier/tier_eq),
            -- not a scorer — partner can't be a scoring dimension any more.
            scorer = { "neg", { "normalize", { "field", "price_in" } } },
            retry_policy = "default",
        },
    },
    retry_policies = {
        default = {
            rate_limit     = { action = "next_candidate" },
            timeout        = { action = "next_candidate" },
            server_error   = { action = "next_candidate" },
            auth_error     = { action = "disable_provider" },
            content_filter = { action = "abort" },
            unknown        = { action = "next_candidate" },
        },
    },
}
