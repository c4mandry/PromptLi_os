"""Agent loop and local-model wrapper for AIDO.

The agent converts natural-language requests into tool calls using a local
GGUF model (llama-cpp-python). It runs a simple, robust loop::

    user message → model generates JSON → execute tool(s) → feed results
    back to the model → repeat until the model returns a plain answer.

llama-cpp-python is imported lazily, so AIDO can be installed and its tools
tested without a model or GPU.
"""

from __future__ import annotations

import json
import logging
import os
from functools import partial
from pathlib import Path
from typing import Any

import tools
import utils

logger = logging.getLogger("aido.agent")

SYSTEM_PROMPT = """You are AIDO (AI Desktop Operator), a helpful assistant that controls a Linux desktop computer.

Available tools:
{tools}

Rules:
- Respond with EXACTLY ONE JSON object, nothing else.
- To call one tool: {{"tool": "<name>", "arguments": {{"<arg>": <value>}}}}
- To call several tools at once: {{"tools": [{{"tool": "...", "arguments": {{...}}}}, ...]}}
- When you have all the information you need, finish with: {{"answer": "your reply to the user"}}
- Prefer actually performing the requested action over describing it.
- Base your answer on the tool results you receive; do not invent facts.
- For destructive actions (closing windows, killing processes) the system may ask the user first.
"""


def format_tool_schemas(registry: list[dict[str, Any]]) -> str:
    """Render the tool registry as prompt-friendly text."""
    lines = []
    for tool in registry:
        params = tool.get("parameters") or {}
        param_text = ", ".join(f"{name} ({desc})" for name, desc in params.items()) or "none"
        lines.append(f"- {tool['name']}: {tool['description']} Parameters: {param_text}.")
    return "\n".join(lines)


def build_tools(config: dict[str, Any]) -> dict[str, Any]:
    """Bind config-provided defaults (safety, web settings) to tool functions."""
    safety = config.get("safety", {})
    web = config.get("web", {})
    allowed_dirs = safety.get("allowed_dirs") or ["~"]
    file_tools = {
        "list_files",
        "find_files",
        "file_info",
        "read_config",
        "edit_config",
        "backup_config",
        "restore_config",
    }
    bound: dict[str, Any] = {}
    for name, fn in tools.TOOL_FUNCTIONS.items():
        if name == "edit_config":
            bound[name] = partial(
                fn,
                allowed_dirs=allowed_dirs,
                auto_backup=safety.get("auto_backup_configs", True),
            )
        elif name in file_tools:
            bound[name] = partial(fn, allowed_dirs=allowed_dirs)
        elif name == "browse_page":
            bound[name] = partial(fn, headless=web.get("browser_headless", True))
        elif name == "download_file":
            bound[name] = partial(
                fn,
                downloads_dir=web.get("download_dir", "~/Downloads"),
                timeout=web.get("download_timeout", 120),
            )
        else:
            bound[name] = fn
    return bound


class Agent:
    """Tool-calling agent backed by a local GGUF model.

    The model can be injected for testing (anything exposing
    ``create_chat_completion(messages, **kwargs)`` returning the llama-cpp
    completion dict); otherwise it is loaded from *model_path*.
    """

    def __init__(
        self,
        model_path: str | None = None,
        config: dict[str, Any] | None = None,
        model: Any = None,
        confirm: Any = None,
    ):
        """*confirm*, when given, is a ``callable(name, arguments) -> bool``
        used instead of the terminal prompt for destructive tools (the GUI
        installs a dialog-based one)."""
        self.config = config or {}
        self.confirm = confirm
        self.tools = build_tools(self.config)
        self.dangerous = {tool["name"] for tool in tools.TOOL_REGISTRY if tool.get("dangerous")}
        agent_cfg = self.config.get("agent", {})
        self.max_iterations = int(agent_cfg.get("max_tool_iterations", 5))
        self.max_history = int(agent_cfg.get("max_history_messages", 12))
        model_cfg = self.config.get("model", {})
        self.max_tokens = int(model_cfg.get("max_tokens", 512))
        self.temperature = float(model_cfg.get("temperature", 0.2))
        self.top_p = float(model_cfg.get("top_p", 0.9))
        self.context_size = int(model_cfg.get("context_size", 2048))
        self.system_prompt = SYSTEM_PROMPT.format(tools=format_tool_schemas(tools.TOOL_REGISTRY))
        self.history: list[dict[str, str]] = []
        self.model = model if model is not None else self._load_model(model_path)

    # -- model loading -----------------------------------------------------

    def _load_model(self, model_path: str | None):
        path = Path(model_path).expanduser() if model_path else None
        if path is None or not path.is_file():
            raise utils.AidoError(
                f"Model file not found: {path}\n\n"
                "Download the Granite 1B GGUF (~700MB):\n"
                "  scripts/download_model.sh\n"
                f"  # or: wget -O <path> {utils.MODEL_URL}\n"
                "or point --model at your own .gguf file."
            )
        try:
            from llama_cpp import Llama
        except ImportError:
            raise utils.AidoError(
                "llama-cpp-python is not installed. Run: pip install llama-cpp-python"
            ) from None
        logger.info("Loading model %s (context %d)", path, self.context_size)
        return Llama(
            model_path=str(path),
            n_ctx=self.context_size,
            n_threads=os.cpu_count() or 4,
            verbose=False,
        )

    # -- conversation ------------------------------------------------------

    def chat(self, message: str, interactive: bool | None = None, assume_yes: bool = False) -> dict[str, Any]:
        """Process one user message.

        Returns ``{"answer": str, "tool_calls": [...], "iterations": int}``.
        """
        self.history.append({"role": "user", "content": message})
        messages: list[dict[str, str]] = [
            {"role": "system", "content": self.system_prompt},
            *self.history[-self.max_history :],
        ]
        tool_calls: list[dict[str, Any]] = []
        for iteration in range(self.max_iterations):
            content = self._generate(messages)
            self.history.append({"role": "assistant", "content": content})
            messages.append({"role": "assistant", "content": content})
            parsed = utils.extract_json(content)
            if parsed is None:
                # No JSON at all — treat the model's text as the final answer.
                return {"answer": content, "tool_calls": tool_calls, "iterations": iteration + 1}
            if "answer" in parsed:
                return {"answer": str(parsed["answer"]), "tool_calls": tool_calls, "iterations": iteration + 1}
            calls = self._collect_calls(parsed)
            if not calls:
                return {"answer": content, "tool_calls": tool_calls, "iterations": iteration + 1}
            results = [self._execute(call, interactive, assume_yes) for call in calls]
            tool_calls.extend(calls)
            tool_message = {
                "role": "user",
                "content": "Tool results (JSON):\n" + json.dumps(results, ensure_ascii=False),
            }
            self.history.append(tool_message)
            messages.append(tool_message)
        summary = f"I could not finish within {self.max_iterations} tool steps."
        if tool_calls:
            summary += f" Last tool used: '{tool_calls[-1].get('tool')}'."
        return {"answer": summary, "tool_calls": tool_calls, "iterations": self.max_iterations}

    @staticmethod
    def _collect_calls(parsed: dict[str, Any]) -> list[dict[str, Any]]:
        """Normalize a parsed response into a list of tool calls."""
        if "tools" in parsed and isinstance(parsed["tools"], list):
            return [call for call in parsed["tools"] if isinstance(call, dict) and "tool" in call]
        if "tool" in parsed:
            return [{"tool": parsed["tool"], "arguments": parsed.get("arguments") or {}}]
        return []

    def _execute(self, call: dict[str, Any], interactive: bool | None, assume_yes: bool) -> dict[str, Any]:
        """Run one tool call with safety checks; never lets an error kill the loop."""
        name = call.get("tool")
        if not isinstance(name, str):
            return {"tool": str(name), "error": f"Tool call is missing a string 'tool' name: {call!r}."}
        result: dict[str, Any] = {"tool": name}
        arguments = call.get("arguments") or {}
        fn = self.tools.get(name)
        if fn is None:
            result["error"] = f"Unknown tool '{name}'. Available tools: {', '.join(sorted(self.tools))}."
            return result
        if name in self.dangerous:
            if self.confirm is not None:
                approved = bool(self.confirm(name, arguments))
            else:
                approved = utils.ask_confirmation(
                    f"⚠️  Tool '{name}' with arguments {arguments} is risky. Allow?",
                    assume_yes=assume_yes,
                    interactive=interactive,
                )
            if not approved:
                result["error"] = "Rejected by user."
                return result
        try:
            result["result"] = fn(**arguments)
        except utils.AidoError as exc:
            result["error"] = str(exc)
        except TypeError as exc:
            result["error"] = f"Invalid arguments for '{name}': {exc}"
        except Exception as exc:  # tool bugs must not kill the session
            logger.exception("Tool '%s' raised an unexpected error", name)
            result["error"] = f"Tool '{name}' failed unexpectedly: {exc}"
        logger.info("tool=%s arguments=%s result=%s", name, arguments, result)
        return result

    def _generate(self, messages: list[dict[str, str]]) -> str:
        kwargs = {
            "messages": messages,
            "max_tokens": self.max_tokens,
            "temperature": self.temperature,
            "top_p": self.top_p,
        }
        try:
            # Force valid JSON via a GBNF grammar where supported.
            completion = self.model.create_chat_completion(
                **kwargs, response_format={"type": "json_object"}
            )
        except (TypeError, ValueError):
            completion = self.model.create_chat_completion(**kwargs)
        return (completion["choices"][0]["message"]["content"] or "").strip()

    def reset(self) -> None:
        """Forget the conversation history."""
        self.history.clear()

    def close(self) -> None:
        """Release model resources explicitly."""
        close = getattr(self.model, "close", None)
        if callable(close):
            close()
