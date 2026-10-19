#!/usr/bin/env python3
"""AIDO — AI Desktop Operator (headless / terminal edition).

Command-line interface for the AIDO agent.

- ``aido``            → aichat-style chat REPL (sessions, roles, streaming)
- ``aido tui``        → the classic full-screen curses chat
- ``aido "question"`` → one-shot natural-language command
- ``aido tools``      → list available tools
- ``aido setup``      → download a local model + install the LLM backend
- ``aido doctor``     → diagnose backend/model/network/API key
- ``aido key``        → manage the encrypted remote API key (sudo)

The GUI/tray/voice frontends were removed: promptLi OS is a headless,
server-focused system, so AIDO lives in the terminal only.
"""

from __future__ import annotations

import argparse
import sys

import utils
from agent import Agent
from repl import render_markdown


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="aido",
        description="AIDO — a local, private AI assistant that controls your promptLi OS machine from the terminal.",
        epilog=(
            "Examples:\n"
            "  aido                start chatting (aichat-style REPL)\n"
            "  aido -s dev         chat in the 'dev' session\n"
            "  aido -r             resume the most recent session\n"
            "  aido \"show disk usage\"\n"
            "  aido \"install htop\"\n"
            "  aido tui            the full-screen curses chat\n"
            "  aido tools          list what AIDO can do\n"
            "  aido doctor         diagnose backend/model/network\n"
            "  aido key set        store an encrypted API key (sudo)\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "command",
        nargs="*",
        help="one-shot natural-language command, or one of: chat | tui | tools | setup | doctor | key",
    )
    parser.add_argument(
        "-s", "--session",
        metavar="NAME",
        help="chat in this session (saved under ~/.aido/sessions).",
    )
    parser.add_argument(
        "-r", "--resume",
        action="store_true",
        help="resume the most recently used session.",
    )
    parser.add_argument(
        "-e", "--execute",
        metavar="TEXT",
        help="run one question and exit (same as `aido \"question\"`).",
    )
    parser.add_argument(
        "--model",
        metavar="PATH",
        help="path to a .gguf model file (default: from config or ~/.aido/models).",
    )
    parser.add_argument(
        "--config",
        metavar="PATH",
        help="path to a YAML config file (default: config/aido.yaml).",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="automatically approve destructive tool calls (use with care).",
    )
    parser.add_argument(
        "--list-tools",
        action="store_true",
        help="print the tools AIDO can use and exit (same as `aido tools`).",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="show tool calls as they happen.",
    )
    return parser


def _print_error(message: str) -> None:
    print(f"❌ {message}", file=sys.stderr)


def _print_tools() -> None:
    from tools import TOOL_REGISTRY

    print("AIDO tools:")
    for tool in TOOL_REGISTRY:
        params = ", ".join(tool.get("parameters", {})) or "—"
        flag = "  (requires confirmation)" if tool.get("dangerous") else ""
        print(f"  {tool['name']:<18} {tool['description']}{flag}")
        print(f"{'':<20} params: {params}")
    print("\nRun 'aido' and ask in plain language, e.g. \"What's in my Downloads folder?\"")


def _load_agent(args: argparse.Namespace) -> tuple[Agent, dict]:
    """Load config + model and return the agent. Raises AidoError with a
    friendly message when the LLM backend/model is missing."""
    config = utils.load_config(args.config)
    utils.setup_logging(
        log_dir=config.get("logging", {}).get("dir"),
        level=config.get("logging", {}).get("level", "INFO"),
    )
    model_path = utils.resolve_model_path(explicit=args.model, config=config)
    agent = Agent(model_path=str(model_path), config=config)
    return agent, config


def _run_setup() -> int:
    """Bootstrap the local model + LLM backend."""
    import subprocess
    from pathlib import Path

    model_path = Path(utils.expand_path("~/.aido/models/granite.gguf"))
    print("AIDO setup — installs the local LLM backend and downloads a model.\n")
    print("[1/2] Installing llama-cpp-python (prebuilt wheel when available; source build otherwise)...")
    ok = False
    try:
        # Prefer the prebuilt manylinux wheel (seconds); fall back to a
        # source compile (minutes) only when no wheel exists for this system.
        subprocess.run(
            [sys.executable, "-m", "pip", "install", "--break-system-packages",
             "--prefer-binary", "llama-cpp-python"],
            check=True,
        )
        ok = True
    except Exception:
        pass
    if not ok:
        try:
            subprocess.run(
                [sys.executable, "-m", "pip", "install", "--break-system-packages", "llama-cpp-python"],
                check=True,
            )
        except Exception as exc:
            _print_error(f"llama-cpp-python install failed: {exc}")
            return 1
    print(f"[2/2] Downloading Granite 4.0 H 1B (Q4_K_M) to {model_path} ...")
    try:
        import requests  # lazily; requests is a light dependency

        model_path.parent.mkdir(parents=True, exist_ok=True)
        with requests.get(utils.MODEL_URL, stream=True, timeout=300) as resp:
            resp.raise_for_status()
            with open(model_path, "wb") as fh:
                for chunk in resp.iter_content(1024 * 1024):
                    fh.write(chunk)
    except Exception as exc:
        _print_error(f"model download failed: {exc}")
        return 1
    print(f"✅ AIDO is ready. Try: aido chat  (model: {model_path})")
    return 0


def _run_doctor() -> int:
    """Diagnose the AIDO install: backend, model, config, network, API key."""
    from pathlib import Path

    print("AIDO doctor\n")
    rows: list[tuple[str, str]] = []

    # Python + backend
    rows.append(("python", sys.version.split()[0]))
    try:
        import llama_cpp  # noqa: F401

        rows.append(("llama-cpp-python", "installed"))
    except ImportError:
        rows.append(("llama-cpp-python", "MISSING — run: aido setup"))

    # Model
    model_dir = Path(utils.expand_path("~/.aido/models"))
    models = sorted(model_dir.glob("*.gguf")) if model_dir.is_dir() else []
    if models:
        for m in models:
            size_mb = m.stat().st_size // (1024 * 1024)
            rows.append(("model", f"{m.name} ({size_mb}MB)"))
    else:
        rows.append(("model", "MISSING — run: aido setup"))

    # Config
    cfg = utils.load_config(None)
    rows.append(("config", "defaults" if not (Path.home() / ".aido" / "aido.yaml").is_file() else "~/.aido/aido.yaml"))

    # API key
    try:
        from secrets import SECRET_PATH

        rows.append(("API key", "set (encrypted)" if SECRET_PATH.is_file() else "not set (aido key set)"))
    except Exception:
        rows.append(("API key", "unknown"))

    # Network to the model host (best effort, short timeout)
    try:
        import requests

        requests.head(utils.MODEL_URL, timeout=6)
        rows.append(("network (huggingface)", "reachable"))
    except Exception:
        rows.append(("network (huggingface)", "unreachable (or slow)"))

    width = max(len(k) for k, _ in rows)
    for key, value in rows:
        print(f"  {key:<{width}}  {value}")
    print("\nTip: `aido setup` installs the backend + model; `aido key set` stores an API key.")
    return 0


def _run_tui(args: argparse.Namespace) -> int:
    """Full-screen chat TUI (bare `aido` or `aido chat`).

    Degrades gracefully: a missing model gives the friendly `aido setup`
    hint, and a terminal without curses support falls back to the line REPL.
    """
    from tui import ensure_config, run_tui

    try:
        config = ensure_config(args.config)
    except Exception as exc:
        _print_error(str(exc))
        return 1
    utils.setup_logging(
        log_dir=config.get("logging", {}).get("dir"),
        level=config.get("logging", {}).get("level", "INFO"),
    )
    try:
        model_path = utils.resolve_model_path(explicit=args.model, config=config)
    except utils.AidoError as exc:
        _print_error(str(exc))
        print("Tip: run `aido setup` to install the local model first.")
        return 1
    try:
        import curses

        return run_tui(
            lambda: Agent(model_path=str(model_path), config=config),
            config,
            str(model_path),
        )
    except curses.error:
        # Terminal cannot do curses (TERM unset/dumb, serial vt220, …) —
        # fall back to the aichat-style REPL.
        return _run_repl_entry(args)


def _run_repl_entry(args: argparse.Namespace) -> int:
    """Start the aichat-style REPL (model errors are friendly + actionable)."""
    from repl import run_repl

    config = utils.load_config(args.config)
    utils.setup_logging(
        log_dir=config.get("logging", {}).get("dir"),
        level=config.get("logging", {}).get("level", "INFO"),
    )
    try:
        model_path = utils.resolve_model_path(explicit=args.model, config=config)
    except utils.AidoError as exc:
        _print_error(str(exc))
        print("Tip: run `aido doctor` to diagnose, or `aido setup` to install the local model.")
        return 1
    try:
        return run_repl(
            lambda: Agent(model_path=str(model_path), config=config),
            config,
            str(model_path),
            session_name=args.session,
            resume_last=args.resume,
        )
    except utils.AidoError as exc:
        _print_error(str(exc))
        return 1


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    # One-shot via -e/--execute (aichat-style).
    if args.execute:
        args.command = [args.execute]

    if args.list_tools:
        _print_tools()
        return 0

    # Subcommands (no model needed for tools/setup/doctor/key).
    if args.command:
        head = args.command[0]
        if head == "tools":
            _print_tools()
            return 0
        if head == "key":
            import secrets

            op = args.command[1] if len(args.command) > 1 else "show"
            if op in ("set", "add"):
                return secrets.key_set()
            if op in ("show", "get"):
                return secrets.key_show()
            if op in ("clear", "remove", "rm"):
                return secrets.key_clear()
            print("usage: aido key set|show|clear", file=sys.stderr)
            return 1
        if head == "setup":
            return _run_setup()
        if head == "doctor":
            return _run_doctor()
        if head == "tui":
            return _run_tui(args)
        if head == "chat":
            return _run_repl_entry(args)

    # Bare `aido` → the aichat-style REPL.
    if not args.command:
        return _run_repl_entry(args)

    # One-shot natural-language command.
    try:
        agent, _config = _load_agent(args)
    except utils.AidoError as exc:
        _print_error(str(exc))
        print("Tip: run `aido doctor` to diagnose, or `aido setup` to install the local model.")
        return 1

    try:
        question = " ".join(args.command)
        result = agent.chat(question, interactive=sys.stdin.isatty(), assume_yes=args.yes)
        if args.verbose:
            for call in result["tool_calls"]:
                print(f"  ⚙️  {call.get('tool')} {call.get('arguments')}")
        print(render_markdown(str(result["answer"])))
        return 0
    except utils.AidoError as exc:
        _print_error(str(exc))
        return 1
    finally:
        agent.close()


if __name__ == "__main__":
    sys.exit(main())
