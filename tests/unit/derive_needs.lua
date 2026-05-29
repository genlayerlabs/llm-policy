-- derive_implicit_needs: contract content infers capability requirements.

local t = require("_assert")
local router = dofile("router.lua")
local r = router._test

t.test("empty contract derives nothing", function()
    local needs = r.derive_implicit_needs({})
    local count = 0
    for _ in pairs(needs) do count = count + 1 end
    t.eq(count, 0, "no needs")
end)

t.test("explicit needs are passed through", function()
    local needs = r.derive_implicit_needs({
        requirements = { needs = { "vision", "tools" } },
    })
    t.truthy(needs.vision, "vision present")
    t.truthy(needs.tools,  "tools present")
end)

t.test("images list implies vision", function()
    local needs = r.derive_implicit_needs({
        images = { { url = "https://example.test/img.png" } },
    })
    t.truthy(needs.vision)
end)

t.test("empty images list does not imply vision", function()
    local needs = r.derive_implicit_needs({ images = {} })
    t.falsy(needs.vision)
end)

t.test("tools list implies tools", function()
    local needs = r.derive_implicit_needs({
        tools = { { type = "function", ["function"] = { name = "x" } } },
    })
    t.truthy(needs.tools)
end)

t.test("response_format json_object implies json_mode", function()
    local needs = r.derive_implicit_needs({
        response_format = { type = "json_object" },
    })
    t.truthy(needs.json_mode)
end)

t.test("response_format text does NOT imply json_mode", function()
    local needs = r.derive_implicit_needs({
        response_format = { type = "text" },
    })
    t.falsy(needs.json_mode)
end)

t.test("explicit + implicit combine without overwriting", function()
    local needs = r.derive_implicit_needs({
        requirements = { needs = { "seed" } },
        images = { { url = "x" } },
    })
    t.truthy(needs.seed,   "explicit kept")
    t.truthy(needs.vision, "implicit added")
end)
