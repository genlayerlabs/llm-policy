-- Pure policy verbs (llm_policy.filter / llm_policy.rank): they read ctx, never
-- a global, and reproduce today's filtering/scoring. The selector is the only
-- place ctx.seed enters (convergence vs divergence).

local t = require("_assert")
local F = require("llm_policy.filter")
local R = require("llm_policy.rank")

local function candidates()
    return {
        { provider_id = "p1", model_family = "m1", tier = "partner",
          capabilities = { context = 8000 }, quality_hint = 0.7 },
        { provider_id = "p2", model_family = "m1", tier = "partner",
          capabilities = { context = 8000 }, quality_hint = 0.7 },
        { provider_id = "p3", model_family = "m1", tier = "fallback",
          capabilities = { context = 8000 }, quality_hint = 0.7 },
    }
end

local function ctx(overrides)
    local c = {
        request = { requirements = {} },
        state   = { ema = {}, breakers = {}, disabled = {},
                    credits = {}, free_credit_threshold_usd = 1.0 },
        now_ms  = 0,
        seed    = nil,
    }
    for k, v in pairs(overrides or {}) do c[k] = v end
    return c
end

local function filter_pool(pred, cands, c)
    local kept, reasons = {}, {}
    for _, cand in ipairs(cands) do
        local ok, why = pred(cand, c)
        if ok then kept[#kept + 1] = cand else reasons[cand.provider_id] = why end
    end
    return kept, reasons
end

-- ---- filter ---------------------------------------------------------------

t.test("requirements passes when capabilities suffice", function()
    local pred = F.all_of{ F.requirements(), F.not_disabled(), F.breaker_closed() }
    local kept = filter_pool(pred, candidates(), ctx())
    t.eq(#kept, 3, "all three pass an empty requirement set")
end)

t.test("min_context rejects with reason", function()
    local pred = F.requirements()
    local _, reasons = filter_pool(pred, candidates(),
        ctx({ request = { requirements = { min_context = 10000 } } }))
    t.eq(reasons.p1, "min_context", "reason propagated for trace.rejected")
end)

t.test("disabled provider is filtered with reason", function()
    local c = ctx()
    c.state.disabled.p1 = "auth_error"
    local pred = F.all_of{ F.requirements(), F.not_disabled() }
    local kept, reasons = filter_pool(pred, candidates(), c)
    t.eq(#kept, 2)
    t.eq(reasons.p1, "disabled_provider")
end)

t.test("tier_in keeps only matching tiers", function()
    local kept = filter_pool(F.tier_in{ "partner" }, candidates(), ctx())
    t.eq(#kept, 2, "only the two partner candidates")
end)

t.test("scope_matches keeps global + matching-scope candidates", function()
    local cands = candidates()
    cands[1].scope = "agent:1"      -- private to agent:1
    local pred = F.scope_matches()
    local kept_other = filter_pool(pred, cands, ctx({ request = { scope = "agent:2" } }))
    t.eq(#kept_other, 2, "scoped p1 hidden from agent:2; globals stay")
    local kept_own = filter_pool(pred, cands, ctx({ request = { scope = "agent:1" } }))
    t.eq(#kept_own, 3, "agent:1 sees its private candidate")
end)

-- ---- rank: weighted + argmax reproduces today's scoring -------------------

t.test("partner-weighted argmax ranks partners over fallback", function()
    local sel = R.argmax(R.weighted{ partner = 1.0 })
    local ordered = sel(candidates(), ctx())
    t.eq(ordered[1].candidate.tier, "partner")
    t.eq(ordered[3].candidate.tier, "fallback", "fallback last")
    t.eq(ordered[3].score, 0.0, "fallback scores 0 under pure partner weight")
end)

t.test("balanced weights reproduce the known cold-start scores", function()
    local sel = R.argmax(R.weighted{ quality = 0.3, speed = 0.2, cost = 0.2, partner = 0.3 })
    local ordered = sel(candidates(), ctx())
    -- partner: 0.3*0.7 + 0.2*0.5 + 0.2*1.0 + 0.3*1.0 = 0.81
    -- fallback:0.3*0.7 + 0.2*0.5 + 0.2*1.0 + 0.3*0.0 = 0.51
    t.truthy(math.abs(ordered[1].score - 0.81) < 1e-9, "top score 0.81")
    t.eq(ordered[3].candidate.provider_id, "p3")
    t.truthy(math.abs(ordered[3].score - 0.51) < 1e-9, "fallback score 0.51")
end)

t.test("open breaker gates score to 0 (still listed, last)", function()
    local c = ctx()
    c.state.breakers.p1 = true
    local sel = R.argmax(R.weighted{ partner = 1.0 })
    local ordered = sel(candidates(), c)
    -- p1 (partner) is gated to 0, so it falls to the bottom alongside p3.
    t.eq(ordered[#ordered].score, 0.0)
    local p1_last = ordered[#ordered].candidate.provider_id == "p1"
                 or ordered[#ordered - 1].candidate.provider_id == "p1"
    t.truthy(p1_last, "breaker-open p1 sinks to the bottom")
end)

-- ---- selector + seed: convergence vs divergence ---------------------------

t.test("softmax_sample is reproducible for a fixed seed", function()
    local sel = R.softmax_sample(R.weighted{ partner = 1.0 }, { temp = 0.5 })
    local a = sel(candidates(), ctx({ seed = 42 }))
    local b = sel(candidates(), ctx({ seed = 42 }))
    for i = 1, #a do
        t.eq(a[i].candidate.provider_id, b[i].candidate.provider_id,
             "same seed => identical order at position " .. i)
    end
end)

t.test("seed drives divergence from argmax", function()
    -- two partners tie at the top; argmax (stable) always puts p1 first.
    local amax = R.argmax(R.weighted{ partner = 1.0 })(candidates(), ctx())
    t.eq(amax[1].candidate.provider_id, "p1")
    local sel = R.softmax_sample(R.weighted{ partner = 1.0 }, { temp = 0.5 })
    local diverged = false
    for seed = 1, 30 do
        if sel(candidates(), ctx({ seed = seed }))[1].candidate.provider_id ~= "p1" then
            diverged = true; break
        end
    end
    t.truthy(diverged, "some seed picks a non-argmax top candidate")
end)

-- ---- R.chain: deterministic priority chain (the greybox selector) ---------

t.test("chain orders by priority and drops non-listed candidates", function()
    local sel = R.chain{ { provider = "p2", model = "m1" },
                         { provider = "p1", model = "m1" } }
    local ordered = sel(candidates(), ctx())
    t.eq(#ordered, 2, "p3 dropped (not in the chain)")
    t.eq(ordered[1].candidate.provider_id, "p2", "p2 is priority 1")
    t.eq(ordered[2].candidate.provider_id, "p1", "p1 is priority 2")
end)

t.test("chain is identical across calls (deterministic, node-independent given same chain)", function()
    local sel = R.chain{ { provider = "p1", model = "m1" }, { provider = "p3", model = "m1" } }
    local a = sel(candidates(), ctx({ seed = 1 }))
    local b = sel(candidates(), ctx({ seed = 999 }))
    t.eq(a[1].candidate.provider_id, b[1].candidate.provider_id, "seed-independent")
    t.eq(a[1].candidate.provider_id, "p1")
end)
