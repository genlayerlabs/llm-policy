-- Profile inheritance resolution: extends, deep merge, cycle detection.

local t = require("_assert")
local router = dofile("router.lua")
local r = router._test

t.test("profile without extends is returned as a deep copy", function()
    local profiles = {
        base = { weights = { quality = 1.0, speed = 0.5 } },
    }
    local rp = r.resolve_profile("base", profiles)
    t.eq(rp.weights.quality, 1.0, "quality preserved")
    t.eq(rp.weights.speed,   0.5, "speed preserved")

    -- mutate result; original should not change
    rp.weights.quality = 999
    t.eq(profiles.base.weights.quality, 1.0, "original profile not mutated")
end)

t.test("child profile inherits and overrides parent weights", function()
    local profiles = {
        base = { weights = { quality = 1.0, speed = 1.0, cost = 1.0 } },
        fast = { extends = "base", weights = { speed = 5.0 } },
    }
    local rp = r.resolve_profile("fast", profiles)
    t.eq(rp.weights.quality, 1.0, "parent quality inherited")
    t.eq(rp.weights.speed,   5.0, "child speed overrides")
    t.eq(rp.weights.cost,    1.0, "parent cost inherited")
end)

t.test("child profile inherits non-weights fields", function()
    local profiles = {
        base = { retry_policy = "balanced", weights = { quality = 1 } },
        derived = { extends = "base", weights = { quality = 2 } },
    }
    local rp = r.resolve_profile("derived", profiles)
    t.eq(rp.retry_policy, "balanced", "retry_policy inherited")
end)

t.test("hard_constraints from parent merge with child", function()
    local profiles = {
        base = { weights = {}, hard_constraints = { privacy = "tee_required" } },
        sub  = { extends = "base", weights = {}, hard_constraints = { min_quality = 0.8 } },
    }
    local rp = r.resolve_profile("sub", profiles)
    t.eq(rp.hard_constraints.privacy,    "tee_required", "parent constraint inherited")
    t.eq(rp.hard_constraints.min_quality, 0.8,           "child constraint added")
end)

t.test("cycle detection raises", function()
    local profiles = {
        a = { extends = "b", weights = {} },
        b = { extends = "a", weights = {} },
    }
    local ok, err = pcall(r.resolve_profile, "a", profiles)
    t.falsy(ok, "should error")
    t.contains(err, "cycle", "error mentions cycle")
end)

t.test("multi-level inheritance flattens correctly", function()
    local profiles = {
        root  = { weights = { quality = 1, speed = 1, cost = 1 } },
        mid   = { extends = "root", weights = { speed = 2 } },
        leaf  = { extends = "mid",  weights = { cost  = 3 } },
    }
    local rp = r.resolve_profile("leaf", profiles)
    t.eq(rp.weights.quality, 1, "from root")
    t.eq(rp.weights.speed,   2, "from mid")
    t.eq(rp.weights.cost,    3, "from leaf")
end)
