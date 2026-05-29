-- router.lua — embeddable LLM router
--
-- Public API (see DESIGN.md §15 for full surface):
--   router.init(config, metrics?)              -> ok, err
--   router.execute(contract)                   -> { ok, response, error, trace, chosen }
--   router.execute_step(state_handle, contract?) -> { status = "done"|"wait", ... }
--   router.update_metrics(provider, model, delta)
--   router.invalidate_discovery(discovery_id)
--   router.dump_state() / router.restore_state(snapshot)
--   router.info()
--
-- The host must provide a `host` global with at least:
--   call_provider, now_ms, env, log
-- and optionally:
--   discover, sleep_ms, persist_state, load_state
--
-- This file does no I/O. The host owns all of it.

local M = {}

M.VERSION = "0.0.1"

-- ===========================================================================
-- Internal state
-- ===========================================================================

-- Frozen-after-init knowledge derived from config + metrics
local CATALOG = {
    providers = nil,    -- [provider_id] = provider_table
    models    = nil,    -- [model_family] = model_table
    profiles  = nil,    -- [profile_name] = resolved profile (inheritance flattened, weights renormalized)
    retry     = nil,    -- [retry_policy_name] = { [error_kind] = action_table }
    candidates = nil,   -- list of { provider_id, model_family, served_model_id, capabilities }
}

-- Mutable runtime state. dump_state/restore_state work on this.
local RUNTIME = {
    circuit_breakers   = {},  -- [provider_id] = { open, opened_at_ms, consecutive_failures }
    ema_metrics        = {},  -- [provider_id .. "|" .. model_family] = { ema_latency_ms, success_rate_ewma, n }
    disabled_providers = {},  -- [provider_id] = reason_string
    discovery_cache    = {},  -- [discovery_id] = { offers, fetched_at_ms }
    initialized        = false,
}

-- Defaults that can be overridden by config.defaults
local DEFAULTS = {
    circuit_breaker_threshold       = 3,
    circuit_breaker_rate_limit_ms   = 30 * 1000,
    circuit_breaker_failure_ms      = 5 * 60 * 1000,
    discovery_cache_ttl_ms          = 60 * 1000,
    ema_alpha                       = 0.2,
    free_credit_threshold_usd       = 1.0,
}

-- ===========================================================================
-- Helpers
-- ===========================================================================

local function clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local function shallow_copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

local function deep_copy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deep_copy(v) end
    return c
end

local function table_keys(t)
    local ks = {}
    for k, _ in pairs(t) do ks[#ks + 1] = k end
    return ks
end

local function table_contains(t, v)
    for _, x in ipairs(t) do
        if x == v then return true end
    end
    return false
end

local function pm_key(provider_id, model_family)
    return provider_id .. "|" .. model_family
end

local function host_log(level, event, fields)
    if host and host.log then
        host.log(level, event, fields or {})
    end
end

-- ===========================================================================
-- Config validation
-- ===========================================================================

local VALID_TIERS    = { partner = true, marketplace = true, fallback = true }
local VALID_API_KIND = { openai_compatible = true, anthropic = true, google = true, ollama = true }
local VALID_PRIVACY  = { standard = true, no_log = true, tee_required = true }
local VALID_DISCOVERY = { static = true, marketplace = true }

local function validate_provider(id, p)
    if type(p) ~= "table" then return "providers." .. id .. " is not a table" end
    if not VALID_DISCOVERY[p.discovery] then
        return "providers." .. id .. ".discovery must be one of: static, marketplace"
    end
    if p.discovery == "static" and (type(p.base_url) ~= "string" or p.base_url == "") then
        return "providers." .. id .. ".base_url required for discovery=static"
    end
    if p.discovery == "marketplace" and type(p.discovery_id) ~= "string" then
        return "providers." .. id .. ".discovery_id required for discovery=marketplace"
    end
    if not VALID_API_KIND[p.api_kind] then
        return "providers." .. id .. ".api_kind must be one of: openai_compatible, anthropic, google, ollama"
    end
    if p.tier ~= nil and not VALID_TIERS[p.tier] then
        return "providers." .. id .. ".tier must be one of: partner, marketplace, fallback"
    end
    return nil
end

local function validate_model(family, m, providers)
    if type(m) ~= "table" then return "models." .. family .. " is not a table" end
    if type(m.served_by) ~= "table" or #m.served_by == 0 then
        return "models." .. family .. ".served_by must be a non-empty list"
    end
    for i, s in ipairs(m.served_by) do
        if type(s.provider) ~= "string" or providers[s.provider] == nil then
            return "models." .. family .. ".served_by[" .. i .. "].provider does not resolve"
        end
    end
    if type(m.capabilities) ~= "table" then
        return "models." .. family .. ".capabilities required"
    end
    return nil
end

local function validate_profile(name, p, profiles_table)
    if type(p) ~= "table" then return "profiles." .. name .. " is not a table" end
    if p.extends ~= nil and profiles_table[p.extends] == nil then
        return "profiles." .. name .. ".extends references unknown profile: " .. tostring(p.extends)
    end
    if p.weights ~= nil and type(p.weights) ~= "table" then
        return "profiles." .. name .. ".weights must be a table"
    end
    return nil
end

local function validate_config(config)
    if type(config) ~= "table" then return "config must be a table" end
    if type(config.providers) ~= "table" then return "config.providers required" end
    if type(config.models) ~= "table" then return "config.models required" end
    if type(config.profiles) ~= "table" then return "config.profiles required" end

    for id, p in pairs(config.providers) do
        local err = validate_provider(id, p)
        if err then return err end
    end
    for family, m in pairs(config.models) do
        local err = validate_model(family, m, config.providers)
        if err then return err end
    end
    for name, prof in pairs(config.profiles) do
        local err = validate_profile(name, prof, config.profiles)
        if err then return err end
    end
    return nil
end

-- ===========================================================================
-- Profile inheritance resolution
-- ===========================================================================

local function resolve_profile(name, profiles_table, seen)
    seen = seen or {}
    if seen[name] then
        error("profile inheritance cycle through: " .. name)
    end
    seen[name] = true

    local p = profiles_table[name]
    if p.extends == nil then
        return deep_copy(p)
    end

    local parent = resolve_profile(p.extends, profiles_table, seen)
    -- shallow merge: child fields override parent fields
    local merged = parent
    for k, v in pairs(p) do
        if k ~= "extends" then
            if type(v) == "table" and type(merged[k]) == "table" then
                -- shallow merge nested tables (weights, hard_constraints, etc.)
                local sub = shallow_copy(merged[k])
                for kk, vv in pairs(v) do sub[kk] = vv end
                merged[k] = sub
            else
                merged[k] = deep_copy(v)
            end
        end
    end
    return merged
end

local function renormalize_weights(weights)
    if weights == nil then return { quality = 1.0 } end
    local sum = 0
    for _, v in pairs(weights) do
        if type(v) == "number" and v > 0 then sum = sum + v end
    end
    if sum == 0 then return weights end
    local out = {}
    for k, v in pairs(weights) do
        if type(v) == "number" and v > 0 then
            out[k] = v / sum
        else
            out[k] = 0
        end
    end
    return out
end

-- ===========================================================================
-- Candidate matrix
-- ===========================================================================

-- Pre-compute the cross product of (provider, model) pairs at init time.
-- Marketplace providers contribute nothing here; their candidates are appended
-- per call from host.discover().
local function build_candidate_matrix(providers, models)
    local list = {}
    for family, m in pairs(models) do
        for _, served in ipairs(m.served_by) do
            local p = providers[served.provider]
            if p ~= nil and p.discovery == "static" then
                list[#list + 1] = {
                    provider_id      = served.provider,
                    model_family     = family,
                    served_model_id  = served.provider_model_id or family,
                    capabilities     = m.capabilities,
                    quality_hint     = m.static_quality_hint,
                    tier             = p.tier or "fallback",
                    has_tee          = p.has_tee or false,
                    no_log           = p.no_log or false,
                    base_url         = p.base_url,
                    auth_env         = p.auth_env,
                    api_kind         = p.api_kind,
                    discovery        = "static",
                }
            end
        end
    end
    return list
end

-- ===========================================================================
-- Metrics seeding
-- ===========================================================================

local function seed_runtime_from_metrics(metrics)
    if metrics == nil then return end
    if type(metrics.models) == "table" then
        for key, mm in pairs(metrics.models) do
            -- key is "<family>@<provider>" per metrics.toml convention; tolerate "<provider>|<family>" too
            local provider, family
            local at = string.find(key, "@", 1, true)
            local bar = string.find(key, "|", 1, true)
            if at then
                family   = string.sub(key, 1, at - 1)
                provider = string.sub(key, at + 1)
            elseif bar then
                provider = string.sub(key, 1, bar - 1)
                family   = string.sub(key, bar + 1)
            else
                -- skip malformed
                goto continue
            end
            local k = pm_key(provider, family)
            RUNTIME.ema_metrics[k] = {
                ema_latency_ms    = mm.ttft_ms_p50,
                ema_tok_s         = mm.tok_s_p50,
                success_rate_ewma = mm.success_rate_24h or 1.0,
                price_in          = mm.price_in_usd_per_mtok,
                price_out         = mm.price_out_usd_per_mtok,
                n                 = 0,  -- bench observations don't count as live observations
            }
            ::continue::
        end
    end
    if type(metrics.providers) == "table" then
        for pid, pm in pairs(metrics.providers) do
            if pm.free_credits_remaining_usd ~= nil then
                RUNTIME.disabled_providers[pid] = nil
                -- Stash credit balance under a synthetic per-provider slot so scoring can read it
                RUNTIME.ema_metrics["__credits|" .. pid] = {
                    free_credits_remaining_usd = pm.free_credits_remaining_usd,
                }
            end
        end
    end
end

-- ===========================================================================
-- Public API: init
-- ===========================================================================

function M.init(config, metrics)
    local err = validate_config(config)
    if err then
        return false, err
    end

    -- Resolve profile inheritance and renormalize weights
    local resolved_profiles = {}
    for name, _ in pairs(config.profiles) do
        local rp = resolve_profile(name, config.profiles)
        rp.weights = renormalize_weights(rp.weights)
        resolved_profiles[name] = rp
    end

    -- Apply defaults overrides
    if type(config.defaults) == "table" then
        for k, v in pairs(config.defaults) do
            DEFAULTS[k] = v
        end
    end

    CATALOG.providers  = config.providers
    CATALOG.models     = config.models
    CATALOG.profiles   = resolved_profiles
    CATALOG.retry      = config.retry_policies or {}
    CATALOG.candidates = build_candidate_matrix(config.providers, config.models)

    -- Reset runtime, then seed from metrics
    RUNTIME.circuit_breakers   = {}
    RUNTIME.ema_metrics        = {}
    RUNTIME.disabled_providers = {}
    RUNTIME.discovery_cache    = {}
    seed_runtime_from_metrics(metrics)
    RUNTIME.initialized = true

    host_log("info", "router_initialized", {
        providers_loaded = #table_keys(CATALOG.providers),
        models_loaded    = #table_keys(CATALOG.models),
        profiles_loaded  = #table_keys(CATALOG.profiles),
        candidates       = #CATALOG.candidates,
        version          = M.VERSION,
    })

    return true, nil
end

-- ===========================================================================
-- Public API: introspection
-- ===========================================================================

function M.info()
    if not RUNTIME.initialized then
        return { initialized = false }
    end
    return {
        version           = M.VERSION,
        initialized       = true,
        providers_loaded  = table_keys(CATALOG.providers),
        models_loaded     = table_keys(CATALOG.models),
        profile_names     = table_keys(CATALOG.profiles),
        candidates        = #CATALOG.candidates,
    }
end

-- ===========================================================================
-- Public API: state
-- ===========================================================================

function M.dump_state()
    return deep_copy(RUNTIME)
end

function M.restore_state(snapshot)
    if type(snapshot) ~= "table" then return false, "snapshot must be a table" end
    for k, v in pairs(snapshot) do
        if k ~= "initialized" then
            RUNTIME[k] = deep_copy(v)
        end
    end
    return true, nil
end

function M.update_metrics(provider_id, model_family, delta)
    local k = pm_key(provider_id, model_family)
    local cur = RUNTIME.ema_metrics[k] or { n = 0 }
    for kk, vv in pairs(delta) do cur[kk] = vv end
    RUNTIME.ema_metrics[k] = cur
end

function M.invalidate_discovery(discovery_id)
    RUNTIME.discovery_cache[discovery_id] = nil
end

-- ===========================================================================
-- Marketplace discovery
-- ===========================================================================

-- Returns a list of dynamic candidates assembled from host.discover() for every
-- marketplace provider in the catalog. Cached per discovery_id for TTL ms.
local function gather_marketplace_candidates(now_ms)
    local out = {}
    if not host or not host.discover then return out end

    for pid, p in pairs(CATALOG.providers) do
        if p.discovery == "marketplace" then
            local cached = RUNTIME.discovery_cache[p.discovery_id]
            local fresh = cached
                and (now_ms - (cached.fetched_at_ms or 0) < DEFAULTS.discovery_cache_ttl_ms)
            local offers
            if fresh then
                offers = cached.offers
            else
                local r = host.discover(p.discovery_id)
                if r and r.ok and type(r.offers) == "table" then
                    offers = r.offers
                    RUNTIME.discovery_cache[p.discovery_id] = {
                        offers = offers,
                        fetched_at_ms = r.fetched_at_ms or now_ms,
                    }
                else
                    host_log("warn", "discovery_failed", {
                        provider = pid,
                        discovery_id = p.discovery_id,
                        error = r and r.error or "no response",
                    })
                    offers = {}
                end
            end

            for _, offer in ipairs(offers or {}) do
                -- skip expired quotes
                if not offer.expires_at_ms or offer.expires_at_ms > now_ms then
                    out[#out + 1] = {
                        provider_id     = pid,
                        model_family    = offer.model_family,
                        served_model_id = offer.model_family,
                        capabilities    = offer.capabilities or {},
                        quality_hint    = offer.quality_hint,
                        tier            = p.tier or "marketplace",
                        has_tee         = p.has_tee or false,
                        no_log          = p.no_log or false,
                        base_url        = offer.seller_endpoint,
                        auth_env        = p.auth_env,
                        api_kind        = p.api_kind,
                        discovery       = "marketplace",
                        offer           = offer,   -- forwarded to host.call_provider
                    }
                end
            end
        end
    end
    return out
end

-- ===========================================================================
-- Auto-derive capability needs from contract content
-- ===========================================================================

local function derive_implicit_needs(contract)
    local needs = {}
    local req = contract.requirements or {}
    if type(req.needs) == "table" then
        for _, n in ipairs(req.needs) do needs[n] = true end
    end
    if type(contract.images) == "table" and #contract.images > 0 then
        needs.vision = true
    end
    if type(contract.tools) == "table" and #contract.tools > 0 then
        needs.tools = true
    end
    if type(contract.response_format) == "table"
       and contract.response_format.type == "json_object" then
        needs.json_mode = true
    end
    return needs
end

-- ===========================================================================
-- Filtering: hard requirements
-- ===========================================================================

-- Map need_name -> capability_flag on the model
local NEED_TO_CAP = {
    tools      = "supports_tools",
    vision     = "supports_vision",
    json_mode  = "supports_json_mode",
    seed       = "supports_seed",
}

local function candidate_passes(cand, contract, needs)
    local req = contract.requirements or {}
    local caps = cand.capabilities or {}

    -- capability needs
    for need, _ in pairs(needs) do
        local flag = NEED_TO_CAP[need]
        if flag and not caps[flag] then return false, "missing_capability:" .. need end
    end

    -- context window
    if req.min_context and (caps.context or 0) < req.min_context then
        return false, "min_context"
    end

    -- model_family filter
    if req.model_family and cand.model_family ~= req.model_family then
        return false, "model_family"
    end

    -- tier filter
    if req.tier and cand.tier ~= req.tier then
        return false, "tier"
    end

    -- privacy filter
    if req.privacy == "tee_required" and not cand.has_tee then
        return false, "tee_required"
    end
    if req.privacy == "no_log" and not (cand.no_log or cand.has_tee) then
        return false, "no_log"
    end

    -- min_quality on static hint
    if req.min_quality and (cand.quality_hint or 0) < req.min_quality then
        return false, "min_quality"
    end

    -- min_tok_s on observed metrics (from EMA seeded by bench)
    if req.min_tok_s then
        local m = RUNTIME.ema_metrics[pm_key(cand.provider_id, cand.model_family)]
        local observed = m and m.ema_tok_s or nil
        if observed == nil or observed < req.min_tok_s then
            return false, "min_tok_s"
        end
    end

    -- disabled providers (auth_error etc.)
    if RUNTIME.disabled_providers[cand.provider_id] then
        return false, "disabled_provider"
    end

    return true, nil
end

local function filter_candidates(contract, now_ms)
    local req = contract.requirements or {}

    -- Pin short-circuits everything
    if req.pin then
        local pp = req.pin.provider
        local pm = req.pin.model
        for _, cand in ipairs(CATALOG.candidates) do
            if cand.provider_id == pp and cand.model_family == pm then
                return { cand }, {}
            end
        end
        return {}, { { reason = "pin_not_found", pin = req.pin } }
    end

    local needs = derive_implicit_needs(contract)
    local survivors, rejected = {}, {}

    local pool = {}
    for _, c in ipairs(CATALOG.candidates) do pool[#pool + 1] = c end
    for _, c in ipairs(gather_marketplace_candidates(now_ms)) do pool[#pool + 1] = c end

    for _, cand in ipairs(pool) do
        local ok, why = candidate_passes(cand, contract, needs)
        if ok then
            survivors[#survivors + 1] = cand
        else
            rejected[#rejected + 1] = {
                provider = cand.provider_id, model = cand.model_family, reason = why,
            }
        end
    end

    return survivors, rejected
end

-- ===========================================================================
-- Scoring
-- ===========================================================================

local function score_quality(cand)
    local m = RUNTIME.ema_metrics[pm_key(cand.provider_id, cand.model_family)]
    local q = (m and m.last_quality_eval) or cand.quality_hint or 0.5
    return clamp(q, 0, 1)
end

local function score_speed(cand, contract)
    local req = contract.requirements or {}
    local target = req.max_latency_ms or 5000   -- ms; "what we'd consider acceptable"
    local m = RUNTIME.ema_metrics[pm_key(cand.provider_id, cand.model_family)]
    local lat = m and m.ema_latency_ms
    if lat == nil then return 0.5 end           -- neutral when unknown
    return clamp(1 - (lat / target), 0, 1)
end

-- Coarse cost estimate per call: assume 1000 input + 500 output tokens unless
-- the contract hints otherwise. Free providers always score 1.0.
local function score_cost(cand, contract)
    local req = contract.requirements or {}
    local m = RUNTIME.ema_metrics[pm_key(cand.provider_id, cand.model_family)]
    local price_in  = (m and m.price_in)  or 0
    local price_out = (m and m.price_out) or 0
    local in_toks  = (req.estimated_input_tokens  or 1000)
    local out_toks = (req.estimated_output_tokens or 500)
    local cost_usd = (price_in * in_toks + price_out * out_toks) / 1e6
    if cost_usd <= 0 then return 1.0 end
    local target = req.max_cost_usd or 0.01
    return clamp(1 - (cost_usd / target), 0, 1)
end

local function score_free(cand)
    local credits_slot = RUNTIME.ema_metrics["__credits|" .. cand.provider_id]
    if credits_slot and (credits_slot.free_credits_remaining_usd or 0) >= DEFAULTS.free_credit_threshold_usd then
        return 1.0
    end
    return 0.0
end

local TIER_SCORE = { partner = 1.0, marketplace = 0.5, fallback = 0.0 }

local function score_partner(cand)
    return TIER_SCORE[cand.tier or "fallback"] or 0
end

local function circuit_breaker_state(provider_id, now_ms)
    local b = RUNTIME.circuit_breakers[provider_id]
    if not b or not b.open then return false end
    local since = now_ms - (b.opened_at_ms or 0)
    local ttl = DEFAULTS.circuit_breaker_rate_limit_ms
    if since >= ttl then
        -- breaker auto-recovers
        b.open = false
        b.consecutive_failures = 0
        return false
    end
    return true
end

local function merged_weights(profile, contract)
    local w = shallow_copy(profile.weights or {})
    local ov = contract.weights_override
    if type(ov) == "table" then
        for k, v in pairs(ov) do w[k] = v end
    end
    return renormalize_weights(w)
end

local function score_candidate(cand, profile, contract, now_ms)
    local w = merged_weights(profile, contract)
    local Q = score_quality(cand)
    local S = score_speed(cand, contract)
    local C = score_cost(cand, contract)
    local F = score_free(cand)
    local P = score_partner(cand)

    local breaker_open = circuit_breaker_state(cand.provider_id, now_ms)

    local raw = (w.quality or 0) * Q
              + (w.speed or 0) * S
              + (w.cost or 0) * C
              + (w.free_credit or 0) * F
              + (w.partner or 0) * P

    local score = breaker_open and 0 or raw

    return score, {
        quality = Q, speed = S, cost = C, free_credit = F, partner = P,
        weights = w, raw = raw, breaker_open = breaker_open,
    }
end

local function rank_candidates(contract, now_ms)
    local profile_name = contract.profile or "default"
    local profile = CATALOG.profiles[profile_name]
    if profile == nil then
        return nil, "unknown profile: " .. tostring(profile_name), {}
    end

    local survivors, rejected = filter_candidates(contract, now_ms)
    local scored = {}
    for _, cand in ipairs(survivors) do
        local s, breakdown = score_candidate(cand, profile, contract, now_ms)
        scored[#scored + 1] = { candidate = cand, score = s, score_breakdown = breakdown }
    end

    table.sort(scored, function(a, b) return a.score > b.score end)

    return scored, nil, rejected
end

-- ===========================================================================
-- Orchestration helpers (used by M.execute)
-- ===========================================================================

local function build_request(cand, contract)
    local messages
    if type(contract.messages) == "table" then
        messages = contract.messages
    elseif contract.prompt ~= nil then
        messages = { { role = "user", content = contract.prompt } }
    else
        messages = {}
    end

    local req = {
        provider_id     = cand.provider_id,
        model_family    = cand.model_family,
        served_model_id = cand.served_model_id,
        base_url        = cand.base_url,
        api_kind        = cand.api_kind,
        auth_env        = cand.auth_env,
        messages        = messages,
        tools           = contract.tools,
        response_format = contract.response_format,
        images          = contract.images,
        temperature     = contract.temperature,
        seed            = contract.seed,
        max_tokens      = contract.max_tokens,
        -- timeout_ms is the hard abort threshold for the host's HTTP call.
        -- Distinct from requirements.max_latency_ms, which is a scoring
        -- preference. Fall back to max_latency_ms only when timeout_ms is
        -- absent, so older contracts keep working.
        timeout_ms      = contract.timeout_ms
                          or (contract.requirements and contract.requirements.max_latency_ms)
                          or 30000,
    }
    if cand.discovery == "marketplace" then
        req.offer = cand.offer
    end
    return req
end

local function update_breaker_on_failure(provider_id, now_ms, open_breaker_ms)
    local b = RUNTIME.circuit_breakers[provider_id]
            or { open = false, consecutive_failures = 0 }
    b.consecutive_failures = (b.consecutive_failures or 0) + 1
    if open_breaker_ms or b.consecutive_failures >= DEFAULTS.circuit_breaker_threshold then
        b.open = true
        b.opened_at_ms = now_ms
    end
    RUNTIME.circuit_breakers[provider_id] = b
end

local function update_breaker_on_success(provider_id)
    local b = RUNTIME.circuit_breakers[provider_id]
    if b then
        b.consecutive_failures = 0
        b.open = false
    end
end

local function update_ema(provider_id, model_family, latency_ms, ok)
    local k = pm_key(provider_id, model_family)
    local m = RUNTIME.ema_metrics[k] or { n = 0 }
    local alpha = DEFAULTS.ema_alpha

    if latency_ms ~= nil then
        if m.ema_latency_ms == nil then
            m.ema_latency_ms = latency_ms
        else
            m.ema_latency_ms = alpha * latency_ms + (1 - alpha) * m.ema_latency_ms
        end
    end

    local s = ok and 1 or 0
    if m.success_rate_ewma == nil then
        m.success_rate_ewma = s
    else
        m.success_rate_ewma = alpha * s + (1 - alpha) * m.success_rate_ewma
    end

    m.n = (m.n or 0) + 1
    RUNTIME.ema_metrics[k] = m
end

local function classify_action(profile, error_kind)
    local policy_name = profile and profile.retry_policy
    local policy = (policy_name and CATALOG.retry[policy_name]) or {}
    return policy[error_kind] or policy.unknown or { action = "next_candidate" }
end

local function backoff_ms_for(action, attempt)
    local b = action.backoff_ms
    if type(b) == "number" then return b end
    if type(b) == "table" then return b[attempt] or b[#b] or 0 end
    return 0
end

local function ranked_summary(ranked)
    local out = {}
    for i, item in ipairs(ranked) do
        out[i] = {
            provider_id  = item.candidate.provider_id,
            model_family = item.candidate.model_family,
            score        = item.score,
            tier         = item.candidate.tier,
        }
    end
    return out
end

-- ===========================================================================
-- Public API: execute (synchronous orchestration loop)
-- ===========================================================================

function M.execute(contract)
    if not RUNTIME.initialized then
        return { ok = false, error = "router not initialized", trace = {} }
    end
    if not (host and host.call_provider) then
        return { ok = false, error = "host.call_provider missing", trace = {} }
    end

    local now_ms = (host and host.now_ms) and host.now_ms or function() return 0 end
    local started_at = now_ms()

    local ranked, err, rejected = rank_candidates(contract, started_at)
    if err then
        return {
            ok = false,
            error = err,
            trace = { rejected = rejected or {}, decision_path = {}, started_at_ms = started_at },
        }
    end

    local trace = {
        ranked         = ranked_summary(ranked),
        rejected       = rejected or {},
        decision_path  = {},
        started_at_ms  = started_at,
    }

    if #ranked == 0 then
        trace.total_latency_ms = now_ms() - started_at
        return { ok = false, error = "no_candidates", trace = trace }
    end

    local profile_name = contract.profile or "default"
    local profile = CATALOG.profiles[profile_name]

    local cursor, attempts = 1, 0
    local last_error_kind

    while cursor <= #ranked do
        local entry = ranked[cursor]
        local cand  = entry.candidate

        if RUNTIME.disabled_providers[cand.provider_id] then
            trace.decision_path[#trace.decision_path + 1] = {
                event        = "skipped",
                provider_id  = cand.provider_id,
                model_family = cand.model_family,
                reason       = "disabled_provider",
            }
            cursor   = cursor + 1
            attempts = 0
        else
            local request    = build_request(cand, contract)
            local call_start = now_ms()
            local response   = host.call_provider(request) or
                                 { ok = false, error_kind = "unknown" }
            local elapsed    = now_ms() - call_start

            update_ema(cand.provider_id, cand.model_family, elapsed, response.ok and true or false)

            local event = {
                event        = "attempted",
                provider_id  = cand.provider_id,
                model_family = cand.model_family,
                attempt      = attempts + 1,
                latency_ms   = elapsed,
            }
            if not response.ok then
                event.error_kind  = response.error_kind or "unknown"
                event.http_status = response.http_status
            end
            trace.decision_path[#trace.decision_path + 1] = event

            if response.ok then
                update_breaker_on_success(cand.provider_id)
                trace.total_latency_ms = now_ms() - started_at
                return {
                    ok       = true,
                    response = response.response,
                    trace    = trace,
                    chosen   = {
                        provider_id     = cand.provider_id,
                        model_family    = cand.model_family,
                        served_model_id = cand.served_model_id,
                    },
                }
            end

            local error_kind = response.error_kind or "unknown"
            last_error_kind  = error_kind

            local action = classify_action(profile, error_kind)
            local act    = action.action or "next_candidate"

            update_breaker_on_failure(cand.provider_id, now_ms(), action.open_breaker_ms)

            if act == "abort" then
                trace.total_latency_ms = now_ms() - started_at
                return { ok = false, error = error_kind, trace = trace }

            elseif act == "disable_provider" then
                RUNTIME.disabled_providers[cand.provider_id] = error_kind
                trace.decision_path[#trace.decision_path + 1] = {
                    event       = "provider_disabled",
                    provider_id = cand.provider_id,
                    reason      = error_kind,
                }
                cursor   = cursor + 1
                attempts = 0

            elseif act == "retry_same" then
                local max = action.attempts or 1
                attempts = attempts + 1
                if attempts <= max then
                    local back = backoff_ms_for(action, attempts)
                    if back > 0 and host.sleep_ms then host.sleep_ms(back) end
                    trace.decision_path[#trace.decision_path + 1] = {
                        event        = "retry_scheduled",
                        provider_id  = cand.provider_id,
                        model_family = cand.model_family,
                        attempt      = attempts,
                        backoff_ms   = back,
                    }
                    -- cursor stays
                else
                    attempts = 0
                    local then_act = action.then_action or "next_candidate"
                    if then_act == "abort" then
                        trace.total_latency_ms = now_ms() - started_at
                        return { ok = false, error = error_kind, trace = trace }
                    else
                        cursor = cursor + 1
                    end
                end

            elseif act == "next_provider_same_model" then
                local target = cand.model_family
                local found
                for j = cursor + 1, #ranked do
                    if ranked[j].candidate.model_family == target then
                        found = j
                        break
                    end
                end
                cursor   = found or (#ranked + 1)
                attempts = 0

            else  -- next_candidate (default) and any unknown action
                cursor   = cursor + 1
                attempts = 0
            end
        end
    end

    trace.total_latency_ms = now_ms() - started_at
    return {
        ok    = false,
        error = "exhausted: " .. (last_error_kind or "no_candidates"),
        trace = trace,
    }
end

function M.execute_step(state_handle, contract)
    error("M.execute_step not implemented yet — cooperative async loop is phase 2b")
end

-- Public dry-run: returns the ranked candidate list without making any HTTP calls.
-- Useful for `conclave explain`-style introspection and for tests.
function M.rank(contract)
    if not RUNTIME.initialized then
        return nil, "router not initialized"
    end
    local now = (host and host.now_ms and host.now_ms()) or 0
    return rank_candidates(contract, now)
end

-- ===========================================================================
-- Test hooks (only exposed to make unit-testing pure helpers possible)
-- These are intentionally underscored to signal "do not use in production code".
-- ===========================================================================

M._test = {
    validate_config        = validate_config,
    resolve_profile        = resolve_profile,
    renormalize_weights    = renormalize_weights,
    build_candidate_matrix = build_candidate_matrix,
    derive_implicit_needs  = derive_implicit_needs,
    filter_candidates      = filter_candidates,
    score_candidate        = score_candidate,
    rank_candidates        = rank_candidates,
    merged_weights         = merged_weights,
    circuit_breaker_state  = circuit_breaker_state,
    build_request          = build_request,
    classify_action        = classify_action,
    backoff_ms_for         = backoff_ms_for,
    clamp                  = clamp,
    pm_key                 = pm_key,
    catalog                = function() return CATALOG end,
    runtime                = function() return RUNTIME end,
    defaults               = function() return DEFAULTS end,
    reset                  = function()
        CATALOG.providers, CATALOG.models, CATALOG.profiles = nil, nil, nil
        CATALOG.retry, CATALOG.candidates = nil, nil
        RUNTIME.circuit_breakers   = {}
        RUNTIME.ema_metrics        = {}
        RUNTIME.disabled_providers = {}
        RUNTIME.discovery_cache    = {}
        RUNTIME.initialized        = false
    end,
}

return M
