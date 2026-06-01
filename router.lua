-- router.lua — compatibility shim.
-- The core is now the `llm_policy` package; this keeps existing embedders
-- (lupa hosts loading "router.lua", genvm `require("router")`) working
-- unchanged. New code should `require("llm_policy")` directly.
-- Parenthesized to force a single return value: require() returns (module, path),
-- and hosts that unpack multiple returns (e.g. lupa) would otherwise get a tuple.
return (require("llm_policy"))
