-- llm_policy.sequence — failure handling: a declarative, CLOSED vocabulary.
--
-- Deliberately NOT combinators. A sequence is a table { [error_kind] = action }
-- over a fixed set of actions; programmable control flow here is where a policy
-- rots into untestable imperative soup (and on-chain becomes an attack surface).
-- See docs/POLICY_DESIGN.md §5.4.

local S = {}

-- The only allowed actions.
S.ACTIONS = {
    retry_same                = true,
    next_candidate            = true,
    next_provider_same_model  = true,
    disable_provider          = true,
    abort                     = true,
}

-- Look up the action for an error kind (pure; takes the resolved table).
function S.classify(retry_table, error_kind)
    retry_table = retry_table or {}
    return retry_table[error_kind] or retry_table.unknown or { action = "next_candidate" }
end

-- Resolve the backoff for an attempt: a number, or an array indexed by attempt.
function S.backoff_ms_for(action, attempt)
    local b = action.backoff_ms
    if type(b) == "number" then return b end
    if type(b) == "table" then return b[attempt] or b[#b] or 0 end
    return 0
end

-- Validate a sequence table: every action must be in the allowed vocabulary.
function S.validate(retry_table)
    if type(retry_table) ~= "table" then return "sequence must be a table" end
    for kind, action in pairs(retry_table) do
        if type(action) ~= "table" or not S.ACTIONS[action.action] then
            return "sequence." .. tostring(kind) .. ".action invalid: " .. tostring(action and action.action)
        end
        local then_act = action.then_action
        if then_act ~= nil and not S.ACTIONS[then_act] then
            return "sequence." .. tostring(kind) .. ".then_action invalid: " .. tostring(then_act)
        end
    end
    return nil
end

return S
