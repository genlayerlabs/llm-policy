-- llm_policy.policy — binds the four verbs into a Policy the engine consumes.
--
--   Policy.new{ filter, select, mutate, sequence }
--     filter   : fn(cand, ctx) -> true | (false, reason)        (or nil = keep all)
--     select   : fn(candidates, ctx) -> ordered [{candidate, score, score_breakdown}]
--     mutate   : fn(request, cand, ctx) -> request'             (default: identity)
--     sequence : { [error_kind] = action } table                (failure handling)
--
-- :plan(candidates, ctx) filters (collecting rejected reasons) then selects.
-- The engine owns the impure orchestration (state snapshot, retries); the verbs
-- it holds are pure. See docs/POLICY_DESIGN.md §6.

local mutate = require("llm_policy.mutate")

local P = {}

function P.new(spec)
    local pol = {
        filter   = spec.filter,
        select   = spec.select,
        mutate   = spec.mutate or mutate.identity,
        sequence = spec.sequence or {},
    }

    function pol.plan(candidates, ctx)
        local survivors, rejected = {}, {}
        -- Expose the input population so population-relative predicates
        -- (in_top_k) can rank against it; ordinary per-candidate predicates
        -- ignore it. Work on a shallow copy so the caller's ctx is never
        -- mutated (the population/memo are internal, never encoded) — term
        -- identities are unaffected.
        local c = {}
        if ctx ~= nil then for k, v in pairs(ctx) do c[k] = v end end
        c.population = candidates
        ctx = c
        for _, cand in ipairs(candidates) do
            local ok, why = true, nil
            if pol.filter then ok, why = pol.filter(cand, ctx) end
            if ok then
                survivors[#survivors + 1] = cand
            else
                rejected[#rejected + 1] = {
                    provider = cand.provider_id, model = cand.model_family, reason = why,
                }
            end
        end
        return { ordered = pol.select(survivors, ctx), rejected = rejected }
    end

    return pol
end

return P
