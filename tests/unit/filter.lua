-- Hard-requirement filtering: each reason a candidate can be rejected.

local t = require("_assert")
local router = dofile("router.lua")
local r = router._test

local function make_config()
    return {
        providers = {
            partner_a = { discovery = "static", base_url = "http://a", api_kind = "openai_compatible", tier = "partner" },
            tee_one   = { discovery = "static", base_url = "http://b", api_kind = "openai_compatible", tier = "partner", has_tee = true, no_log = true },
            mkt_one   = { discovery = "static", base_url = "http://m", api_kind = "openai_compatible", tier = "marketplace" },
        },
        models = {
            chat = {
                served_by = {
                    { provider = "partner_a" },
                    { provider = "tee_one" },
                    { provider = "mkt_one" },
                },
                capabilities = {
                    context            = 8000,
                    supports_tools     = true,
                    supports_json_mode = true,
                },
                static_quality_hint = 0.7,
            },
            vision_model = {
                served_by = { { provider = "partner_a" } },
                capabilities = { context = 4000, supports_vision = true },
                static_quality_hint = 0.65,
            },
        },
        profiles = {
            default = { weights = { quality = 1 } },
        },
    }
end

local function fresh()
    r.reset()
    assert(router.init(make_config()))
end

t.test("tee_required keeps only TEE providers", function()
    fresh()
    local survivors = r.filter_candidates({ requirements = { privacy = "tee_required" } }, 0)
    t.eq(#survivors, 1, "only one survivor")
    t.eq(survivors[1].provider_id, "tee_one", "the TEE provider")
end)

t.test("no_log accepts both no_log and TEE providers", function()
    fresh()
    local survivors = r.filter_candidates({ requirements = { privacy = "no_log" } }, 0)
    -- tee_one has no_log=true; partner_a and mkt_one do not
    t.eq(#survivors, 1)
    t.eq(survivors[1].provider_id, "tee_one")
end)

t.test("vision need filters to vision-capable models", function()
    fresh()
    local contract = { images = { { url = "x" } } }
    local survivors = r.filter_candidates(contract, 0)
    t.eq(#survivors, 1)
    t.eq(survivors[1].model_family, "vision_model")
end)

t.test("min_context filters models with too-small context", function()
    fresh()
    local survivors = r.filter_candidates({ requirements = { min_context = 5000 } }, 0)
    -- chat (8000) survives; vision_model (4000) gone
    for _, s in ipairs(survivors) do
        t.eq(s.model_family, "chat", "only chat model")
    end
end)

t.test("tier filter restricts to a single tier", function()
    fresh()
    local survivors = r.filter_candidates({ requirements = { tier = "marketplace" } }, 0)
    t.eq(#survivors, 1)
    t.eq(survivors[1].provider_id, "mkt_one")
end)

t.test("pin short-circuits to a single candidate", function()
    fresh()
    local survivors, rejected = r.filter_candidates({
        requirements = { pin = { provider = "partner_a", model = "chat" } },
    }, 0)
    t.eq(#survivors, 1)
    t.eq(survivors[1].provider_id, "partner_a")
    t.eq(survivors[1].model_family, "chat")
end)

t.test("pin to non-existent pair returns no survivors and a pin_not_found reason", function()
    fresh()
    local survivors, rejected = r.filter_candidates({
        requirements = { pin = { provider = "bogus", model = "bogus" } },
    }, 0)
    t.eq(#survivors, 0)
    t.eq(#rejected, 1)
    t.eq(rejected[1].reason, "pin_not_found")
end)

t.test("disabled provider is filtered out", function()
    fresh()
    r.runtime().disabled_providers["partner_a"] = "auth_error"
    local survivors = r.filter_candidates({}, 0)
    for _, s in ipairs(survivors) do
        t.falsy(s.provider_id == "partner_a", "partner_a excluded")
    end
end)

t.test("tools need filters to tool-capable models", function()
    fresh()
    local contract = { tools = { { type = "function" } } }
    local survivors = r.filter_candidates(contract, 0)
    -- chat has tools; vision_model doesn't
    for _, s in ipairs(survivors) do
        t.eq(s.model_family, "chat")
    end
end)

t.test("json_mode via response_format filters correctly", function()
    fresh()
    local contract = { response_format = { type = "json_object" } }
    local survivors = r.filter_candidates(contract, 0)
    for _, s in ipairs(survivors) do
        t.eq(s.model_family, "chat", "only json-capable model survives")
    end
end)
