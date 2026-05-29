-- dispatch.lua — drop-in replacement for genvm's `genvm-llm-default.lua`.
--
-- It exposes the same two entry points genvm's Rust side calls into:
--   ExecPrompt(ctx, args, remaining_gen)
--   ExecPromptTemplate(ctx, args, remaining_gen)
-- but instead of the built-in primer-match loop, routing decisions go through
-- `router.lua`: scoring, retry policy, circuit-breaker, optional marketplace.
--
-- The "host" that the router calls back into is a shim that wraps genvm's
-- own `__llm:exec_prompt_in_provider`, so all HTTP/auth still happens in Rust.
-- The Lua side just decides which (provider, model) pair to try next.
--
-- To make different validators diverge their routing decisions ("greybox"),
-- drop a `router-overlay.lua` file on the Lua path that returns a partial
-- config table. It is shallow-merged over the catalog auto-derived from
-- `__llm.providers`. Overlay shape:
--   {
--     providers      = { [name] = { tier = "fallback", ... } },
--     models         = { [name] = { quality = 0.9, capabilities = {...} } },
--     profiles       = { default = { weights = {...}, retry_policy = "..." } },
--     retry_policies = { ... },
--   }

local lib_genvm = require("lib-genvm")
local lib_llm   = require("lib-llm")

-- ---------------------------------------------------------------------------
-- Optional overlay (skipped silently if absent).
-- ---------------------------------------------------------------------------

local function load_overlay()
    local ok, mod = pcall(require, "router-overlay")
    if ok and type(mod) == "table" then return mod end
    return {}
end

-- ---------------------------------------------------------------------------
-- Catalog construction from `__llm.providers`.
--
-- GenVM expresses capabilities per (backend, model) pair. The router expresses
-- them per model_family. When a model name appears under multiple backends
-- with disagreeing caps, we OR the booleans (most permissive) — the Rust side
-- will reject a real call if the chosen pair can't actually do the format,
-- and the router will cascade.
-- ---------------------------------------------------------------------------

local function or_caps(a, b)
    local out = {}
    for k, v in pairs(a or {}) do out[k] = v end
    for k, v in pairs(b or {}) do out[k] = out[k] or v end
    return out
end

local function build_catalog(providers_db, overlay)
    -- model_name -> { served_by = {...}, capabilities = {...} }
    local model_index = {}
    for backend_name, backend in pairs(providers_db) do
        for model_name, model_cfg in pairs(backend.models or {}) do
            local entry = model_index[model_name] or {
                served_by    = {},
                capabilities = {},
            }
            table.insert(entry.served_by, {
                provider          = backend_name,
                provider_model_id = model_name,
            })
            entry.capabilities = or_caps(entry.capabilities, {
                supports_json_mode = model_cfg.supports_json or false,
                supports_vision    = model_cfg.supports_image or false,
                supports_tools     = model_cfg.supports_tools or false,
                supports_seed      = true,
                use_max_completion_tokens = model_cfg.use_max_completion_tokens or false,
            })
            model_index[model_name] = entry
        end
    end

    local providers = {}
    for backend_name, _ in pairs(providers_db) do
        providers[backend_name] = {
            -- The router needs base_url / api_kind / auth_env to satisfy its
            -- schema, but our host shim never uses them (Rust owns transport).
            base_url  = "managed-by-genvm",
            api_kind  = "openai_compatible",
            auth_env  = "managed-by-genvm",
            tier      = "partner",
            discovery = "static",
        }
    end

    local models = {}
    for model_name, entry in pairs(model_index) do
        models[model_name] = {
            served_by          = entry.served_by,
            capabilities       = entry.capabilities,
            static_quality_hint = 0.8,
        }
    end

    -- Apply overlay (shallow per-key merge).
    if overlay.providers then
        for name, ov in pairs(overlay.providers) do
            providers[name] = providers[name] or {}
            for k, v in pairs(ov) do providers[name][k] = v end
        end
    end
    if overlay.models then
        for name, ov in pairs(overlay.models) do
            models[name] = models[name] or { served_by = {}, capabilities = {} }
            for k, v in pairs(ov) do
                if k == "capabilities" then
                    models[name].capabilities = or_caps(models[name].capabilities, v)
                else
                    models[name][k] = v
                end
            end
        end
    end

    local cfg = {
        providers      = providers,
        models         = models,
        profiles       = overlay.profiles or {
            default = {
                weights = {
                    quality     = 0.5,
                    speed       = 0.2,
                    cost        = 0.2,
                    partner     = 0.1,
                    free_credit = 0.0,
                },
                retry_policy = "default",
            },
        },
        retry_policies = overlay.retry_policies or {
            default = {
                rate_limit    = { action = "next_candidate" },
                timeout       = { action = "next_candidate" },
                server_error  = { action = "next_candidate" },
                auth_error    = { action = "disable_provider" },
                content_filter = { action = "abort" },
                unknown       = { action = "next_candidate" },
            },
        },
    }
    return cfg
end

-- ---------------------------------------------------------------------------
-- Host shim: how router.lua reaches back into genvm.
-- ---------------------------------------------------------------------------

-- The genvm ctx is per-call; router.execute is synchronous from our POV, so
-- we just stash it on a closure-captured upvalue before each execute().
local current_ctx = nil

local function classify_status(status)
    if status == 429 then return "rate_limit" end
    if status == 408 or status == 504 then return "timeout" end
    if status == 503 or status == 529 then return "server_error" end
    if status == 401 or status == 403 then return "auth_error" end
    if status == 404 then return "model_unavailable" end
    if status and status >= 500 then return "server_error" end
    if status == 400 then return "bad_request" end
    return "unknown"
end

local function call_provider(req)
    -- Rebuild a genvm-shaped request from the router's transport-agnostic one.
    local system_msg, user_msg
    for _, m in ipairs(req.messages or {}) do
        if m.role == "system" then
            system_msg = (system_msg and (system_msg .. "\n") or "") .. (m.content or "")
        elseif m.role == "user" then
            user_msg = (user_msg and (user_msg .. "\n") or "") .. (m.content or "")
        end
    end

    local prompt = {
        system_message            = system_msg,
        user_message              = user_msg or "",
        temperature               = req.temperature or 0.7,
        images                    = req.images or {},
        max_tokens                = req.max_tokens or 1000,
        use_max_completion_tokens = req.use_max_completion_tokens or false,
        seed                      = req.seed,
    }

    local format = req.response_format
    if type(format) == "table" then
        if format.type == "json_object" then format = "json"
        elseif format.type == "bool"     then format = "bool"
        else format = "text" end
    end
    if format == nil then format = "text" end

    local genvm_req = {
        provider = req.provider_id,
        model    = req.served_model_id,
        prompt   = prompt,
        format   = format,
    }

    local ok, result = pcall(function()
        return lib_llm.rs.exec_prompt_in_provider(current_ctx, genvm_req)
    end)

    if ok then
        return { ok = true, response = result }
    end

    local ue = lib_genvm.rs.as_user_error(result)
    if ue == nil then
        -- Non-user error: fatal, propagate up.
        return {
            ok            = false,
            error_kind    = "fatal",
            error_message = tostring(result),
            _fatal        = true,
            _raw          = result,
        }
    end

    local status = (ue.ctx and ue.ctx.status) or 0
    return {
        ok            = false,
        error_kind    = classify_status(status),
        http_status   = status,
        error_message = tostring(ue.causes or ue),
    }
end

-- Install host BEFORE loading router.lua (router.init reads `host.log`).
_G.host = {
    call_provider = call_provider,
    now_ms        = function()
        local ok, ms = pcall(function() return math.floor(os.clock() * 1000) end)
        if ok then return ms end
        return 0
    end,
    log = function(level, event, fields)
        lib_genvm.log{ level = level, message = event, fields = fields }
    end,
    env      = function(_) return nil end,   -- router does not need env in this embedding
    sleep_ms = nil,                          -- no sleep in module Lua VMs
}

-- ---------------------------------------------------------------------------
-- Load router.lua and initialise once per VM.
-- ---------------------------------------------------------------------------

local router = require("router")

local _catalog = build_catalog(lib_llm.providers, load_overlay())
local _ok, _err = router.init(_catalog)
if not _ok then
    error("dispatch.lua: router.init failed: " .. tostring(_err))
end

lib_genvm.log{
    level   = "info",
    message = "llm-router dispatch initialised",
    providers = (function()
        local out = {}
        for name, _ in pairs(_catalog.providers) do out[#out + 1] = name end
        return out
    end)(),
}

-- ---------------------------------------------------------------------------
-- Helpers to translate genvm's mapped prompt into a router contract.
-- ---------------------------------------------------------------------------

local function build_contract(mapped)
    local messages = {}
    if mapped.prompt.system_message and #mapped.prompt.system_message > 0 then
        table.insert(messages, { role = "system", content = mapped.prompt.system_message })
    end
    table.insert(messages, { role = "user", content = mapped.prompt.user_message })

    local response_format
    if mapped.format == "json" then
        response_format = { type = "json_object" }
    elseif mapped.format == "bool" then
        response_format = { type = "json_object" }   -- bool needs JSON capability
    end

    return {
        profile         = "default",
        messages        = messages,
        temperature     = mapped.prompt.temperature,
        max_tokens      = mapped.prompt.max_tokens,
        seed            = mapped.prompt.seed,
        images          = mapped.prompt.images,
        response_format = response_format,
        -- Internal hints carried to host.call_provider so we can rebuild the
        -- genvm-shaped Prompt accurately.
        use_max_completion_tokens = mapped.prompt.use_max_completion_tokens,
    }
end

local function dispatch(ctx, mapped)
    current_ctx = ctx
    local contract = build_contract(mapped)
    -- Stash the original mapped.format on the contract so call_provider can
    -- pass it through verbatim (router strips unknown keys from req).
    contract.response_format = contract.response_format
                              or (mapped.format == "text" and nil)
                              or { type = "json_object" }

    local result = router.execute(contract)

    if result.ok then
        local r = result.response
        r.consumed_gen = 0
        return r
    end

    -- Map router failure into a genvm user_error so the contract can observe
    -- it via the normal LLM error path.
    lib_genvm.log{
        level   = "error",
        message = "llm-router exhausted all candidates",
        error   = result.error,
        trace   = result.trace,
    }
    lib_genvm.rs.user_error({
        causes = { "ROUTER_FAILED", result.error or "unknown" },
        fatal  = true,
        ctx = {
            error = result.error,
            trace = result.trace,
        },
    })
end

-- ---------------------------------------------------------------------------
-- Entry points called by genvm's Rust side.
-- ---------------------------------------------------------------------------

function ExecPrompt(ctx, args, remaining_gen)
    ---@cast args LLMExecPromptPayload
    args.prompt = lib_genvm.rs.filter_text(args.prompt, {
        'NFKC', 'RmZeroWidth', 'NormalizeWS'
    })
    local mapped = lib_llm.exec_prompt_transform(args)
    return dispatch(ctx, mapped)
end

function ExecPromptTemplate(ctx, args, remaining_gen)
    ---@cast args LLMExecPromptTemplatePayload
    local mapped = lib_llm.exec_prompt_template_transform(args)
    return dispatch(ctx, mapped)
end
