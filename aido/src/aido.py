#!/usr/bin/env python3
"""AIDO — AI Desktop Operator (headless / terminal edition).

Command-line interface for the AIDO agent.

- ``aido``            → full-screen chat TUI (first run asks 2 questions)
- ``aido chat``       → same TUI (line REPL when stdin is not a terminal)
- ``aido "question"`` → one-shot natural-language command
- ``aido tools``      → list available tools
- ``aido setup``      → download a local model + install the LLM backend

The GUI/tray/voice frontends were removed: promptLi OS is a headless,
server-focused system, so AIDO lives in the terminal only.
"""

from __future__ import annotations

import argparse
import sys

import utils
from agent import Agent

BANNER = "🤖 AIDO ready! Type 'exit' to quit."


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="aido",
        description="AIDO — a local, private AI assistant that controls your promptLi OS machine from the terminal.",
        epilog=(
            "Examples:\n"
            "  aido                open the full-screen chat TUI\n"
            "  aido \"show disk usage\"\n"
            "  aido \"install htop\"\n"
            "  aido tools"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "command",
        nargs="*",
        help="one-shot natural-language command, or one of: chat | tools | setup",
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
    print("\nRun 'aido chat' and ask in plain language, e.g. \"What's in my Downloads folder?\"")


def _repl(agent: Agent, assume_yes: bool, verbose: bool) -> int:
    print(BANNER)
    print('Try: "list my home directory", "show memory usage", or \'exit\' to quit.\n')
    while True:
        try:
            line = input("You: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nGoodbye!")
            return 0
        if not line:
            continue
        if line.lower() in ("exit", "quit"):
            print("Goodbye!")
            return 0
        result = agent.chat(line, interactive=True, assume_yes=assume_yes)
        if verbose:
            for call in result["tool_calls"]:
                print(f"  ⚙️  {call.get('tool')} {call.get('arguments')}")
        print(f"AIDO: {result['answer']}\n")


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
    print("[1/2] Installing llama-cpp-python (this compiles, takes a few minutes)...")
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
        # fall back to the plain line REPL.
        try:
            agent = Agent(model_path=str(model_path), config=config)
        except utils.AidoError as exc:
            _print_error(str(exc))
            print("Tip: run `aido setup` to install the local model first.")
            return 1
        try:
            return _repl(agent, assume_yes=args.yes, verbose=args.verbose)
        finally:
            agent.close()


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    # Bare `aido` → the full-screen chat TUI.
    if not args.command and not args.list_tools:
        return _run_tui(args)

    if args.list_tools:
        _print_tools()
        return 0

    # Subcommands (no model needed for tools/setup).
    if args.command:
        head = args.command[0]
        if head == "tools":
            _print_tools()
            return 0
        if head == "setup":
            return _run_setup()
        if head == "chat":
            # Piped/redirected stdin keeps the old line-REPL; a real
            # terminal gets the full-screen TUI.
            if not sys.stdin.isatty():
                try:
                    agent, _config = _load_agent(args)
                except utils.AidoError as exc:
                    _print_error(str(exc))
                    print("Tip: run `aido setup` to install the local model first.")
                    return 1
                try:
                    return _repl(agent, assume_yes=args.yes, verbose=args.verbose)
                except utils.AidoError as exc:
                    _print_error(str(exc))
                    return 1
                finally:
                    agent.close()
            return _run_tui(args)

    # One-shot natural-language command.
    try:
        agent, _config = _load_agent(args)
    except utils.AidoError as exc:
        _print_error(str(exc))
        print("Tip: run `aido setup` to install the local model first.")
        return 1

    try:
        question = " ".join(args.command)
        result = agent.chat(question, interactive=sys.stdin.isatty(), assume_yes=args.yes)
        if args.verbose:
            for call in result["tool_calls"]:
                print(f"  ⚙️  {call.get('tool')} {call.get('arguments')}")
        print(result["answer"])
        return 0
    except utils.AidoError as exc:
        _print_error(str(exc))
        return 1
    finally:
        agent.close()


if __name__ == "__main__":
    sys.exit(main())
