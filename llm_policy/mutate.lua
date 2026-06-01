-- llm_policy.mutate — pure, per-attempt request transforms.
--
-- A mutation is `fn(request, cand, ctx) -> request'`. Runs after a candidate is
-- chosen and before the call, so retries re-diversify. Two sub-kinds, and the
-- split is what keeps the core pure (docs/POLICY_DESIGN.md §5.3):
--   1. param transforms  — applied in Lua (temperature/top_p/seed/max_tokens)
--   2. filter directives — declared as data on request._filters; the HOST runs
--      the actual text/image filters (Rust). The DSL only names a seeded recipe.
--
-- Mutations never do I/O and never touch credentials or candidate selection.

local util = require("llm_policy.util")

local Mut = {}

-- shallow clone so mutations don't alias the caller's request
local function clone(req)
    local c = {}
    for k, v in pairs(req or {}) do c[k] = v end
    return c
end

-- Derive a sub-seed for a named stage so each mutation is independently
-- reproducible from ctx.seed.
local function substream(ctx, salt)
    local base = ctx.seed or 0
    local h = 0
    for i = 1, #salt do h = (h * 31 + salt:byte(i)) % 2147483647 end
    return (base + h) % 2147483647
end

Mut.identity = function(req, _cand, _ctx) return req end

-- Seeded ± jitter on numeric sampling params (no-op when ctx.seed is nil).
function Mut.jitter(spec)
    return function(req, _cand, ctx)
        if ctx.seed == nil then return req end
        local rng = util.lcg(substream(ctx, "jitter"))
        local out = clone(req)
        for param, amount in pairs(spec or {}) do
            local base = out[param]
            if type(base) == "number" and type(amount) == "number" then
                out[param] = base + (rng() * 2 - 1) * amount   -- base ± amount
            elseif type(amount) == "number" then
                out[param] = (rng() * 2 - 1) * amount
            end
        end
        return out
    end
end

-- Set fixed params. `seed = "from_ctx"` injects the per-node seed into the call.
function Mut.set_param(spec)
    return function(req, _cand, ctx)
        local out = clone(req)
        for param, value in pairs(spec or {}) do
            if value == "from_ctx" then out[param] = ctx.seed else out[param] = value end
        end
        return out
    end
end

function Mut.clamp(spec)
    return function(req, _cand, _ctx)
        local out = clone(req)
        for param, hi in pairs(spec or {}) do
            if type(out[param]) == "number" and out[param] > hi then out[param] = hi end
        end
        return out
    end
end

-- Declarative directives: attach a seeded recipe to request._filters; the host
-- applies them (Rust text/image filters). The DSL does NOT run them.
local function attach_directive(kind, recipe)
    return function(req, _cand, ctx)
        local out = clone(req)
        local filters = {}
        for k, v in pairs(out._filters or {}) do filters[k] = v end
        filters[kind] = { recipe = recipe, seed = (ctx.seed and (ctx.seed % 2147483647)) }
        out._filters = filters
        return out
    end
end

function Mut.filter_text(recipe)  return attach_directive("text",  recipe) end
function Mut.filter_image(recipe) return attach_directive("image", recipe) end

-- ---- combinators ----------------------------------------------------------

function Mut.pipe(steps)
    return function(req, cand, ctx)
        for _, step in ipairs(steps) do req = step(req, cand, ctx) end
        return req
    end
end

function Mut.when(pred, m)
    return function(req, cand, ctx)
        if pred(cand, ctx) then return m(req, cand, ctx) end
        return req
    end
end

function Mut.custom(fn) return fn end

return Mut
