-- metrics.example.lua
-- Example metrics seed. The router reads this at init to seed runtime EMAs
-- (price, latency, quality); the live EMA overwrites these as calls happen.
--
-- Keys in `models` use the format "<family>@<provider>" by convention.

return {

    generated_at_iso = "2026-05-19T10:23:00Z",

    providers = {
        comput3 = {
            last_seen_ok                 = "2026-05-19T10:22:48Z",
            free_credits_remaining_usd   = 142.3,
            free_credits_expires_at_iso  = "2026-08-01T00:00:00Z",
        },
        heurist = {
            last_seen_ok                 = "2026-05-19T10:22:30Z",
            free_credits_remaining_usd   = 50.0,
        },
        io_net = {
            last_seen_ok                 = "2026-05-19T10:22:12Z",
        },
        morpheus = {
            last_seen_ok                 = "2026-05-19T10:22:01Z",
        },
        chutes = {
            last_seen_ok                 = "2026-05-19T10:21:55Z",
        },
        atoma = {
            last_seen_ok                 = "2026-05-19T10:21:40Z",
        },
    },

    models = {
        ["hermes-3-405b@comput3"] = {
            price_in_usd_per_mtok  = 0.0,
            price_out_usd_per_mtok = 0.0,
            tok_s_p50              = 42.1,
            tok_s_p95              = 28.4,
            ttft_ms_p50            = 380,
            success_rate_24h       = 0.997,
            last_quality_eval      = 0.79,
            quantization_observed  = "fp8",
        },
        ["deepseek-v3@comput3"] = {
            price_in_usd_per_mtok  = 0.0,
            price_out_usd_per_mtok = 0.0,
            tok_s_p50              = 38.0,
            ttft_ms_p50            = 420,
            success_rate_24h       = 0.995,
        },
        ["deepseek-v3@morpheus"] = {
            price_in_usd_per_mtok  = 0.14,
            price_out_usd_per_mtok = 0.28,
            tok_s_p50              = 35.0,
            ttft_ms_p50            = 510,
            success_rate_24h       = 0.99,
        },
        ["llama-3.3-70b@io_net"] = {
            price_in_usd_per_mtok  = 0.18,
            price_out_usd_per_mtok = 0.18,
            tok_s_p50              = 40.0,
            ttft_ms_p50            = 320,
            success_rate_24h       = 0.998,
        },
    },
}
