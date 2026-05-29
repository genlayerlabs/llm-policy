-- config.live.lua — provider catalog used by `tests/live_smoke.py`.
-- Three providers, one model family (llama-3.3-70b), so we can demonstrate
-- partner-vs-partner ranking AND cascade to a fallback provider.

return {

    providers = {
        heurist = {
            discovery = "static",
            base_url  = "https://llm-gateway.heurist.xyz/v1",
            api_kind  = "openai_compatible",
            auth_env  = "HEURIST_API_KEY",
            tier      = "partner",
            notes     = "Free credits via referral code 'genlayer'",
        },
        io_net = {
            discovery = "static",
            base_url  = "https://api.intelligence.io.solutions/api/v1",
            api_kind  = "openai_compatible",
            auth_env  = "IONET_API_KEY",
            tier      = "partner",
        },
        openrouter = {
            discovery = "static",
            base_url  = "https://openrouter.ai/api/v1",
            api_kind  = "openai_compatible",
            auth_env  = "OPENROUTER_API_KEY",
            tier      = "fallback",
            notes     = "Last-resort gateway",
        },
    },

    models = {
        ["llama-3.3-70b"] = {
            served_by = {
                { provider = "heurist",    provider_model_id = "meta-llama/llama-3.3-70b-instruct" },
                { provider = "io_net",     provider_model_id = "meta-llama/Llama-3.3-70B-Instruct" },
                { provider = "openrouter", provider_model_id = "meta-llama/llama-3.3-70b-instruct" },
            },
            capabilities = {
                context            = 128000,
                supports_tools     = true,
                supports_json_mode = true,
            },
            static_quality_hint = 0.72,
        },
    },

    profiles = {
        default = {
            weights = {
                quality = 0.30,
                speed   = 0.20,
                cost    = 0.20,
                partner = 0.30,
            },
            retry_policy = "balanced",
        },
    },

    retry_policies = {
        balanced = {
            rate_limit        = { action = "next_candidate", open_breaker_ms = 30000 },
            timeout           = { action = "next_candidate" },
            server_error      = { action = "retry_same", attempts = 1, backoff_ms = 500,
                                  then_action = "next_candidate" },
            auth_error        = { action = "disable_provider" },
            bad_request       = { action = "abort" },
            content_filter    = { action = "next_candidate" },
            model_unavailable = { action = "next_provider_same_model", mark_unavailable_ms = 300000 },
            network_error     = { action = "retry_same", attempts = 2, backoff_ms = { 200, 600 },
                                  then_action = "next_candidate" },
            context_overflow  = { action = "abort" },
            unknown           = { action = "next_candidate" },
        },
    },
}
