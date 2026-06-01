-- config.live.lua — provider catalog used by `hosts/python_shim/live_smoke.py`.
-- Primary model is minimax-m2.7 served by OpenRouter — fast, current,
-- and inexpensive. Llama-3.3-70b is kept as a secondary candidate so
-- the cascade behaviour can still be demonstrated when needed.

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
        antseed = {
            discovery = "static",
            base_url  = "http://localhost:8377/v1",
            api_kind  = "openai_compatible",
            auth      = { kind = "none" },   -- local node; no Authorization header
            tier      = "fallback",
            notes     = "Local AntSeed node (npm @antseed/cli). Decentralized meta-router; "
                     .. "pays peers via the node wallet. See docs/PROVIDERS.md.",
        },
        openai = {
            discovery = "static",
            base_url  = "https://chatgpt.com/backend-api/codex",
            api_kind  = "openai_codex",
            auth      = { kind = "oauth", provider = "codex" },
            tier      = "partner",
            notes     = "ChatGPT subscription via Codex proxy. UNOFFICIAL / ToS-risky — "
                     .. "the backend mimics the Codex CLI. See docs/OPENAI-CODEX.md.",
        },
    },

    models = {
        ["minimax-m2.7"] = {
            served_by = {
                { provider = "openrouter", provider_model_id = "minimax/minimax-m2.7" },
            },
            capabilities = {
                context            = 200000,
                supports_tools     = true,
                supports_json_mode = true,
            },
            static_quality_hint = 0.80,
        },
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
        -- Served only by the local AntSeed node, which itself routes to peers
        -- by price/latency/reputation. Opaque downstream → keep it a fallback,
        -- not a quality-rankable partner.
        ["deepseek-v3.1"] = {
            served_by = {
                { provider = "antseed", provider_model_id = "deepseek-v3.1" },
            },
            capabilities = {
                context            = 128000,
                supports_tools     = true,
                supports_json_mode = true,
            },
            static_quality_hint = 0.74,
        },
        -- ChatGPT subscription model, served only through the Codex proxy.
        ["gpt-5.5-codex"] = {
            served_by = {
                { provider = "openai", provider_model_id = "gpt-5.5-codex" },
            },
            capabilities = {
                context            = 400000,
                supports_tools     = true,
                supports_json_mode = true,
            },
            static_quality_hint = 0.92,
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
        -- Profile subzeroclaw asks for via `model = "profile:agent"`. Quality-
        -- led: prefer the strongest model first (gpt-5.5-codex via the ChatGPT
        -- subscription), and lean on the partner gateways + the AntSeed/
        -- OpenRouter fallbacks for cascade when it fails. The shim ignores
        -- whatever model string subzeroclaw sends unless it carries a valid
        -- profile:/family:/pin: prefix, so routing stays server-controlled.
        agent = {
            weights = {
                quality = 0.55,
                speed   = 0.15,
                cost    = 0.05,
                partner = 0.25,
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
