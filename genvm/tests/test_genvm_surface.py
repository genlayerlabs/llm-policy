"""
test_genvm_surface.py — drive `genvm/dispatch.lua` end-to-end without genvm.

This test recreates the Lua surface genvm injects into its LLM module:
- `__llm.providers`     — backends DB
- `__llm.templates`     — prompt templates
- `__llm.exec_prompt_in_provider(ctx, request)` — the async provider call
And mocks `lib-genvm` + `lib-llm` via package.preload so dispatch.lua loads
without the real genvm code on the path.

Then we call `ExecPrompt(ctx, args)` like genvm would, and assert that the
router-driven cascade actually happens: first provider fails, second succeeds.

Run from repo root:
    pytest tests/integration/test_genvm_surface.py -v
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

import lupa
import pytest
from lupa import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
ROUTER_LUA = ROOT / "router.lua"
DISPATCH_LUA = ROOT / "genvm" / "dispatch.lua"


# ---------------------------------------------------------------------------
# Helpers to install fake genvm libs and __llm into a fresh Lua VM.
# ---------------------------------------------------------------------------

LIB_GENVM_FAKE = r"""
-- Fake lib-genvm just enough for dispatch.lua.
local M = {}
M.log = function(t) end  -- swallow logs in tests; override via _G._captured_logs

M.rs = {
    filter_text = function(text, _filters) return text end,

    -- as_user_error: in genvm, returns nil for non-user errors, or a table
    -- with { ctx = { status = ... }, causes = {...} } for user errors.
    -- Our fake protocol: if the Lua error was a table with __user_error=true,
    -- treat it as a user error.
    as_user_error = function(err)
        if type(err) == "table" and err.__user_error then return err end
        if type(err) == "string" then
            -- when pcall returns a string, look for our magic prefix
            local payload = string.match(err, "USER_ERROR:(.+)$")
            if payload then
                local status = tonumber(string.match(payload, "status=(%d+)"))
                return { ctx = { status = status or 0 }, causes = { payload } }
            end
        end
        return nil
    end,

    user_error = function(t)
        -- raise a table-shaped error that our as_user_error can recognise.
        t.__user_error = true
        error(t)
    end,
}

M.get_first_from_table = function(t)
    for k, v in pairs(t or {}) do return { key = k, value = v } end
    return nil
end

return M
"""

LIB_LLM_FAKE = r"""
-- Fake lib-llm: thin wrapper over __llm with the same helpers dispatch.lua
-- depends on (rs, providers, exec_prompt_transform, exec_prompt_template_transform).
local M = {}

M.rs = __llm
M.providers = __llm.providers
M.templates = __llm.templates

-- select_providers_for: genvm filters to prompt/format-compatible backends.
-- For the fake we return the whole providers DB; the greybox chain restricts.
M.select_providers_for = function(_prompt, _format) return __llm.providers end

M.exec_prompt_transform = function(args)
    local mp = {
        system_message = nil,
        user_message   = args.prompt,
        temperature    = 0.7,
        images         = args.images or {},
        max_tokens     = 1000,
        use_max_completion_tokens = false,
    }
    local format = args.response_format or "text"
    if format == "json" then mp.system_message = "respond with a valid json object" end
    return { prompt = mp, format = format }
end

M.exec_prompt_template_transform = function(args)
    -- Not exercised in this test; stubbed to fail loudly if called.
    error("exec_prompt_template_transform not stubbed for this test")
end

return M
"""


def make_runtime(call_handler, providers_db: dict):
    """
    Build a fresh LuaRuntime with our fakes registered, load dispatch.lua,
    and return (lua, dispatch_globals).

    call_handler(provider, model, prompt, format) → either:
      - a dict response (success):           {"data": "Text", "value": "..."}
      - a tuple ("overloaded", status):      raises a user_error with that status
      - a tuple ("fatal", "message"):        raises a non-user-error
    """
    lua = LuaRuntime(unpack_returned_tuples=True)

    # Capture logs for inspection.
    log_records: list[dict] = []

    def py_log(t):
        rec = _to_py(t) or {}
        log_records.append(rec)

    def py_exec_prompt_in_provider(ctx, request):
        req = _to_py(request) or {}
        provider = req.get("provider")
        model    = req.get("model")
        prompt   = req.get("prompt")
        fmt      = req.get("format")
        outcome  = call_handler(provider, model, prompt, fmt)

        if isinstance(outcome, tuple) and outcome[0] == "overloaded":
            # Raise a user-shaped error from Lua via our fake protocol.
            status = outcome[1]
            lua.execute(f'error({{ __user_error = true, ctx = {{ status = {status} }}, causes = {{ "test_overload" }} }})')
        elif isinstance(outcome, tuple) and outcome[0] == "fatal":
            lua.execute(f'error("non-user-error: {outcome[1]}")')
        else:
            return _to_lua(lua, outcome)

    # __llm global with providers, templates, exec_prompt_in_provider.
    lua.globals()["__llm"] = lua.table_from({
        "providers": _to_lua(lua, providers_db),
        "templates": _to_lua(lua, {}),
        "exec_prompt_in_provider": py_exec_prompt_in_provider,
    })

    # Make our fake libs importable via package.preload.
    lua.execute(f"""
        package.preload["lib-genvm"] = function()
            {LIB_GENVM_FAKE}
        end
        package.preload["lib-llm"] = function()
            {LIB_LLM_FAKE}
        end
    """)

    # Override the lib-genvm log inside the preload to use our Python callback.
    # We do this by installing a global that the fake lib-genvm picks up.
    lua.globals()["_py_log"] = py_log
    lua.execute(r"""
        local orig_preload = package.preload["lib-genvm"]
        package.preload["lib-genvm"] = function()
            local M = orig_preload()
            M.log = function(t) _py_log(t) end
            return M
        end
    """)

    # Make router.lua + dispatch.lua require-able.
    router_dir = str(ROUTER_LUA.parent.resolve())
    dispatch_dir = str(DISPATCH_LUA.parent.resolve())
    lua.execute(f"""
        package.path = "{router_dir}/?.lua;{dispatch_dir}/?.lua;" .. package.path
    """)

    # Now load dispatch.lua (which calls router.init at the top level).
    lua.execute(f'dofile("{DISPATCH_LUA.resolve()}")')

    return lua, log_records


# ---------------------------------------------------------------------------
# lupa marshalling helpers
# ---------------------------------------------------------------------------

def _to_py(obj):
    if obj is None: return None
    t = lupa.lua_type(obj)
    if t is None: return obj
    if t != "table": return obj
    keys = list(obj.keys())
    if keys and all(isinstance(k, int) for k in keys) \
            and set(keys) == set(range(1, len(keys) + 1)):
        return [_to_py(obj[i]) for i in range(1, len(keys) + 1)]
    return {k: _to_py(v) for k, v in obj.items()}


def _to_lua(lua, obj):
    if isinstance(obj, dict):
        return lua.table_from({k: _to_lua(lua, v) for k, v in obj.items()})
    if isinstance(obj, (list, tuple)):
        return lua.table_from([_to_lua(lua, x) for x in obj])
    return obj


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

PROVIDERS_DB = {
    "heurist": {
        "models": {
            "meta-llama/llama-3.3-70b-instruct": {
                "supports_json": True, "supports_image": False,
                "use_max_completion_tokens": False,
            },
        },
    },
    "io_net": {
        "models": {
            "meta-llama/Llama-3.3-70B-Instruct": {
                "supports_json": True, "supports_image": False,
                "use_max_completion_tokens": False,
            },
        },
    },
    "openai": {
        "models": {
            "gpt-4o": {
                "supports_json": True, "supports_image": True,
                "use_max_completion_tokens": False,
            },
        },
    },
}


def test_dispatch_loads_and_initialises_router():
    """The Lua side should load without error and ExecPrompt should exist."""
    calls = []
    def handler(p, m, prompt, fmt):
        calls.append((p, m))
        return {"data": {"Text": "pong"}, "consumed_gen": 0}

    lua, logs = make_runtime(handler, PROVIDERS_DB)
    assert lua.globals()["ExecPrompt"] is not None
    assert lua.globals()["ExecPromptTemplate"] is not None
    init_logs = [l for l in logs if "initialised" in (l.get("message") or "")]
    assert init_logs, f"expected an init log, got: {logs}"


def test_exec_prompt_text_succeeds_first_try():
    """Happy path: first provider answers, no cascade."""
    calls = []
    def handler(p, m, prompt, fmt):
        calls.append((p, m))
        return {"data": {"Text": "ok"}, "consumed_gen": 0}

    lua, _ = make_runtime(handler, PROVIDERS_DB)

    ctx = lua.table_from({})
    args = lua.table_from({"prompt": "ping", "response_format": "text", "images": lua.table_from([])})
    result = lua.globals()["ExecPrompt"](ctx, args, 1_000_000)
    py = _to_py(result)

    assert py is not None, "ExecPrompt returned nil"
    assert py["data"]["Text"] == "ok"
    assert py["consumed_gen"] == 0
    assert len(calls) == 1, f"expected one call, got {calls}"


def test_exec_prompt_cascades_on_overload():
    """First provider 429s → router picks the next candidate, succeeds."""
    calls = []
    def handler(p, m, prompt, fmt):
        calls.append((p, m))
        if len(calls) == 1:
            return ("overloaded", 429)
        return {"data": {"Text": "rescued"}, "consumed_gen": 0}

    lua, _ = make_runtime(handler, PROVIDERS_DB)

    ctx = lua.table_from({})
    args = lua.table_from({"prompt": "ping", "response_format": "text", "images": lua.table_from([])})
    result = lua.globals()["ExecPrompt"](ctx, args, 1_000_000)
    py = _to_py(result)

    assert py["data"]["Text"] == "rescued"
    assert len(calls) >= 2, f"expected cascade, got {calls}"


def test_exec_prompt_json_filters_to_json_capable_models():
    """When response_format=json, only json-capable backends should be tried."""
    # Make one of the backends not support json to prove filtering.
    db = {
        "heurist": {
            "models": {
                "text-only-model": {
                    "supports_json": False, "supports_image": False,
                    "use_max_completion_tokens": False,
                },
            },
        },
        "openai": {
            "models": {
                "gpt-4o": {
                    "supports_json": True, "supports_image": False,
                    "use_max_completion_tokens": False,
                },
            },
        },
    }
    calls = []
    def handler(p, m, prompt, fmt):
        calls.append((p, m, fmt))
        return {"data": {"Object": {"k": "v"}}, "consumed_gen": 0}

    lua, _ = make_runtime(handler, db)

    ctx = lua.table_from({})
    args = lua.table_from({"prompt": "ping", "response_format": "json", "images": lua.table_from([])})
    lua.globals()["ExecPrompt"](ctx, args, 1_000_000)

    # The text-only-model under heurist must NOT be invoked.
    invoked_models = {m for _, m, _ in calls}
    assert "text-only-model" not in invoked_models, \
        f"router invoked a non-json-capable model for json format: {calls}"
    assert "gpt-4o" in invoked_models, \
        f"router did not invoke the json-capable model: {calls}"


def test_exec_prompt_all_fail_raises_router_failed():
    """When every candidate fails, the router should exhaust the pool, log the
    failure, and propagate a user_error via lib_genvm.rs.user_error."""
    calls = []
    def handler(p, m, prompt, fmt):
        calls.append((p, m))
        return ("overloaded", 429)

    lua, logs = make_runtime(handler, PROVIDERS_DB)

    ctx = lua.table_from({})
    args = lua.table_from({"prompt": "ping", "response_format": "text", "images": lua.table_from([])})

    with pytest.raises(Exception):
        lua.globals()["ExecPrompt"](ctx, args, 1_000_000)

    # Every provider should have been tried (one model_family per backend, three backends).
    invoked_providers = {p for p, _ in calls}
    assert invoked_providers == {"heurist", "io_net", "openai"}, \
        f"expected all three providers tried, got: {invoked_providers}"

    # The exhaustion log should be present.
    exhaust_logs = [l for l in logs if "exhausted" in (l.get("message") or "")]
    assert exhaust_logs, f"expected an exhaustion log, got: {[l.get('message') for l in logs]}"


# ---------------------------------------------------------------------------
# Greybox: meta.greybox priority chains routed through llm_policy (R.chain)
# ---------------------------------------------------------------------------

GREYBOX_DB = {
    "openrouter": {
        "models": {
            "deepseek/deepseek-v3.2": {
                "supports_json": True, "supports_image": False,
                "meta": {"greybox": {"text": 1}},          # chain priority 1
            },
        },
    },
    "heurist": {
        "models": {
            "meta-llama/llama-3.3-70b-instruct": {
                "supports_json": True, "supports_image": False,
                "meta": {"greybox": {"text": 2}},          # chain priority 2
            },
        },
    },
    "io_net": {
        "models": {
            "some-other-model": {                          # NOT in any chain
                "supports_json": True, "supports_image": False,
            },
        },
    },
}


def test_greybox_chain_order_and_cascade():
    """meta.greybox builds a priority chain; selection follows it; on overload
    the cascade walks to the next chain entry; non-chained providers are never
    tried."""
    calls = []
    def handler(p, m, prompt, fmt):
        calls.append((p, m))
        if len(calls) == 1:
            return ("overloaded", 429)                     # primary overloads
        return {"data": {"Text": "rescued"}, "consumed_gen": 0}

    lua, logs = make_runtime(handler, GREYBOX_DB)

    # confirm greybox mode was detected at init
    init = [l for l in logs if "initialised" in (l.get("message") or "")]
    assert init and init[0].get("greybox") is True, f"greybox not detected: {init}"

    ctx = lua.table_from({})
    args = lua.table_from({"prompt": "ping", "response_format": "text", "images": lua.table_from([])})
    py = _to_py(lua.globals()["ExecPrompt"](ctx, args, 1_000_000))

    assert py["data"]["Text"] == "rescued"
    assert calls[0] == ("openrouter", "deepseek/deepseek-v3.2"), f"priority 1 first, got {calls}"
    assert calls[1] == ("heurist", "meta-llama/llama-3.3-70b-instruct"), f"priority 2 next, got {calls}"
    assert all(p != "io_net" for p, _ in calls), f"non-chained provider was tried: {calls}"


def test_greybox_never_calls_non_chained_provider():
    """Even on total failure, only chained candidates are attempted."""
    calls = []
    def handler(p, m, prompt, fmt):
        calls.append((p, m))
        return ("overloaded", 429)

    lua, _ = make_runtime(handler, GREYBOX_DB)
    ctx = lua.table_from({})
    args = lua.table_from({"prompt": "ping", "response_format": "text", "images": lua.table_from([])})
    with pytest.raises(Exception):
        lua.globals()["ExecPrompt"](ctx, args, 1_000_000)

    tried = {p for p, _ in calls}
    assert tried == {"openrouter", "heurist"}, f"only the chain should be tried, got {tried}"
