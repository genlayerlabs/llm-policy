"""
llm_router_host.py — reference Python embedding of router.lua via lupa.

Loads `router.lua` + `config.lua` (+ optional `metrics.lua`) into a Lua VM,
installs the `host` table the router needs for I/O, and exposes a small
Python API: init / info / rank / execute / dump_state.

`call_provider` defaults to a mock that returns canned responses keyed by
(provider_id, model_family). Tests inject responses via set_mock_response().
A real HTTP backend can be plugged in by passing call_provider=... .

Dependencies:
    pip install lupa>=2.0
    (real-HTTP backend, optional: httpx)
"""
from __future__ import annotations

import os
import time
from pathlib import Path
from typing import Any, Callable

import lupa
from lupa import LuaRuntime

CallProviderHook = Callable[[dict], dict]
DiscoverHook = Callable[[str], dict]
Logger = Callable[[str, str, dict], None]
Clock = Callable[[], int]


class LLMRouterHost:
    def __init__(
        self,
        router_path: str | Path,
        config_path: str | Path,
        metrics_path: str | Path | None = None,
        *,
        call_provider: CallProviderHook | None = None,
        discover: DiscoverHook | None = None,
        env: dict[str, str] | None = None,
        now_ms: Clock | None = None,
        logger: Logger | None = None,
    ):
        self.lua = LuaRuntime(unpack_returned_tuples=True)

        self._call_hook: CallProviderHook = call_provider or _default_mock_call
        self._discover_hook: DiscoverHook | None = discover
        self._env: dict[str, str] = env if env is not None else dict(os.environ)
        self._now_ms: Clock = now_ms or (lambda: int(time.time() * 1000))
        self._logger: Logger = logger or _noop_logger
        self._mock_responses: dict[tuple[str, str], dict] = {}
        self.log_records: list[tuple[str, str, dict]] = []

        # Install host table BEFORE loading router (router.init logs to host.log).
        self._install_host_table()

        self.router = self._dofile(Path(router_path))
        self.config = self._dofile(Path(config_path))
        self.metrics = self._dofile(Path(metrics_path)) if metrics_path else None

    # ---- public API -----------------------------------------------------

    def init(self) -> None:
        ok, err = self.router.init(self.config, self.metrics)
        if not ok:
            raise RuntimeError(f"router.init failed: {err}")

    def info(self) -> dict:
        return _to_py(self.router.info())

    def rank(self, contract: dict) -> tuple[list[dict], list[dict]]:
        """Return (ranked_survivors, rejected). Raises on error."""
        ranked, err, rejected = self.router.rank(_to_lua(self.lua, contract))
        if err:
            raise RuntimeError(f"rank failed: {err}")
        return _to_py(ranked) or [], _to_py(rejected) or []

    def execute(self, contract: dict) -> dict:
        return _to_py(self.router.execute(_to_lua(self.lua, contract)))

    def dump_state(self) -> dict:
        return _to_py(self.router.dump_state())

    def update_metrics(self, provider: str, model: str, delta: dict) -> None:
        self.router.update_metrics(provider, model, _to_lua(self.lua, delta))

    def invalidate_discovery(self, discovery_id: str) -> None:
        self.router.invalidate_discovery(discovery_id)

    # ---- mock control (for tests) --------------------------------------

    def set_mock_response(self, provider: str, model: str, response: dict) -> None:
        self._mock_responses[(provider, model)] = response

    def clear_mocks(self) -> None:
        self._mock_responses.clear()

    def set_discover_hook(self, hook: DiscoverHook | None) -> None:
        self._discover_hook = hook

    # ---- internals -----------------------------------------------------

    def _dofile(self, path: Path):
        # Pass the path through a Lua global to avoid quoting bugs.
        self.lua.globals()["__path"] = str(path.resolve())
        return self.lua.eval("dofile(__path)")

    def _install_host_table(self):
        self.lua.globals()["host"] = self.lua.table_from({
            "now_ms":        self._h_now_ms,
            "log":           self._h_log,
            "env":           self._h_env,
            "call_provider": self._h_call_provider,
            "discover":      self._h_discover,
            "sleep_ms":      self._h_sleep_ms,
        })

    def _h_now_ms(self) -> int:
        return self._now_ms()

    def _h_log(self, level, event, fields):
        py_fields = _to_py(fields) or {}
        self.log_records.append((level, event, py_fields))
        self._logger(level, event, py_fields)

    def _h_env(self, key):
        return self._env.get(key)

    def _h_call_provider(self, request):
        py_req = _to_py(request) or {}
        provider = py_req.get("provider_id")
        model = py_req.get("model_family")
        if (provider, model) in self._mock_responses:
            resp = self._mock_responses[(provider, model)]
        else:
            resp = self._call_hook(py_req)
        return _to_lua(self.lua, resp)

    def _h_discover(self, discovery_id):
        if not self._discover_hook:
            return _to_lua(self.lua, {"ok": False, "error": "no_discover_hook"})
        return _to_lua(self.lua, self._discover_hook(discovery_id))

    def _h_sleep_ms(self, ms):
        time.sleep(float(ms) / 1000.0)


# ---- marshaling helpers -------------------------------------------------

def _to_py(obj):
    """Recursively convert lupa Lua tables to Python dicts/lists."""
    if obj is None:
        return None
    t = lupa.lua_type(obj)
    if t is None:
        return obj
    if t != "table":
        return obj
    keys = list(obj.keys())
    if keys and all(isinstance(k, int) for k in keys) \
            and set(keys) == set(range(1, len(keys) + 1)):
        return [_to_py(obj[i]) for i in range(1, len(keys) + 1)]
    return {k: _to_py(v) for k, v in obj.items()}


def _to_lua(lua: LuaRuntime, obj):
    if isinstance(obj, dict):
        return lua.table_from({k: _to_lua(lua, v) for k, v in obj.items()})
    if isinstance(obj, (list, tuple)):
        return lua.table_from([_to_lua(lua, x) for x in obj])
    return obj


def _default_mock_call(request: dict) -> dict:
    return {
        "ok": False,
        "error_kind": "no_mock_set",
        "http_status": 0,
        "latency_ms": 0,
    }


def _noop_logger(level, event, fields):
    pass


# ---- HTTP-real call_provider (OpenAI-compatible) ------------------------

def make_http_call_provider(
    env_get: Callable[[str], str | None] | None = None,
    timeout_s: float = 30.0,
    extra_headers: dict[str, str] | None = None,
) -> CallProviderHook:
    """
    Return a call_provider that translates the router's request to an
    OpenAI-compatible /chat/completions POST, classifies the HTTP outcome
    to a canonical error_kind, and returns the shape router.lua expects.

    `env_get` reads the bearer token for `request['auth_env']`. Defaults to
    `os.environ.get`.

    Requires `httpx` (pip install httpx).
    """
    import time as _time
    import httpx

    _env_get = env_get or os.environ.get
    _extra = dict(extra_headers or {})

    def call(request: dict) -> dict:
        api_kind = request.get("api_kind", "openai_compatible")
        if api_kind != "openai_compatible":
            return _err("unsupported_api_kind", 0, 0,
                        f"api_kind={api_kind!r} not supported by HTTP backend")

        auth_env = request.get("auth_env")
        token = _env_get(auth_env) if auth_env else None
        if not token:
            return _err("auth_error", 0, 0, f"env var {auth_env!r} unset")

        body: dict = {
            "model":    request["served_model_id"],
            "messages": request.get("messages") or [],
        }
        for field in ("tools", "response_format", "temperature", "seed", "max_tokens"):
            v = request.get(field)
            if v is not None:
                body[field] = v

        url = (request["base_url"] or "").rstrip("/") + "/chat/completions"
        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type":  "application/json",
            **_extra,
        }
        timeout = (request.get("timeout_ms") or int(timeout_s * 1000)) / 1000.0

        t0 = _time.monotonic()
        try:
            resp = httpx.post(url, json=body, headers=headers, timeout=timeout)
        except httpx.TimeoutException:
            return _err("timeout", 0, _elapsed_ms(t0), f"POST {url} timed out")
        except (httpx.NetworkError, httpx.RequestError) as e:
            return _err("network_error", 0, _elapsed_ms(t0), str(e))

        latency = _elapsed_ms(t0)
        status  = resp.status_code

        if 200 <= status < 300:
            try:
                data = resp.json()
            except Exception as e:
                return _err("bad_response", status, latency, f"json parse: {e}")

            choices = data.get("choices") or []
            if not choices:
                return _err("bad_response", status, latency, "no choices in response")

            choice = choices[0]
            finish = choice.get("finish_reason")
            if finish == "content_filter":
                return _err("content_filter", status, latency, "blocked by provider filter")

            msg   = choice.get("message") or {}
            usage = data.get("usage") or {}
            return {
                "ok":         True,
                "latency_ms": latency,
                "response": {
                    "text":          msg.get("content") or "",
                    "tool_calls":    msg.get("tool_calls"),
                    "finish_reason": finish,
                    "tokens_in":     usage.get("prompt_tokens"),
                    "tokens_out":    usage.get("completion_tokens"),
                    "tokens_total":  usage.get("total_tokens"),
                    "raw_model":     data.get("model"),
                },
            }

        # error path
        try:
            err_body = resp.json()
            err_msg  = str(err_body)
        except Exception:
            err_msg = (resp.text or "")[:500]
        return _err(_classify_status(status, err_msg), status, latency, err_msg[:500])

    return call


def _classify_status(status: int, err_msg: str) -> str:
    if status in (401, 403):
        return "auth_error"
    if status == 429:
        return "rate_limit"
    if status in (408, 504):
        return "timeout"
    if status == 404:
        return "model_unavailable"
    if status == 400:
        m = (err_msg or "").lower()
        if "context" in m or "token" in m or "length" in m or "maximum" in m:
            return "context_overflow"
        return "bad_request"
    if 500 <= status < 600:
        return "server_error"
    return "unknown"


def _err(kind: str, status: int, latency_ms: int, message: str) -> dict:
    return {
        "ok":            False,
        "error_kind":    kind,
        "http_status":   status,
        "latency_ms":    latency_ms,
        "error_message": message,
    }


def _elapsed_ms(t0: float) -> int:
    import time as _t
    return int((_t.monotonic() - t0) * 1000)
