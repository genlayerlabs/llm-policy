-- Tiny assertion helper for router unit tests.
-- Stateful: counters accumulate across files when required from a runner.

local M = { passed = 0, failed = 0, errors = 0, current = "(no test)" }

local function fail(msg)
    M.failed = M.failed + 1
    io.write(string.format("  FAIL [%s]: %s\n", M.current, msg or ""))
end

function M.eq(actual, expected, msg)
    if actual == expected then
        M.passed = M.passed + 1
    else
        fail(string.format("%s\n      expected: %s\n      got:      %s",
            msg or "", tostring(expected), tostring(actual)))
    end
end

function M.near(actual, expected, eps, msg)
    eps = eps or 1e-9
    if type(actual) == "number" and math.abs(actual - expected) <= eps then
        M.passed = M.passed + 1
    else
        fail(string.format("%s (|%s - %s| > %s)",
            msg or "", tostring(actual), tostring(expected), tostring(eps)))
    end
end

function M.truthy(v, msg)
    if v then
        M.passed = M.passed + 1
    else
        fail(string.format("%s (was falsy: %s)", msg or "", tostring(v)))
    end
end

function M.falsy(v, msg)
    if not v then
        M.passed = M.passed + 1
    else
        fail(string.format("%s (was truthy: %s)", msg or "", tostring(v)))
    end
end

function M.contains(s, sub, msg)
    if type(s) == "string" and string.find(s, sub, 1, true) then
        M.passed = M.passed + 1
    else
        fail(string.format("%s (expected substring %q in %s)",
            msg or "", tostring(sub), tostring(s)))
    end
end

function M.test(name, fn)
    M.current = name
    local ok, err = pcall(fn)
    if not ok then
        M.errors = M.errors + 1
        io.write(string.format("  ERROR [%s]: %s\n", name, tostring(err)))
    end
end

function M.summary()
    io.write(string.format(
        "\n%d passed, %d failed, %d errors\n",
        M.passed, M.failed, M.errors))
    return M.failed + M.errors
end

return M
