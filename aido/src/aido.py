#!/usr/bin/env python3
"""AIDO — AI Desktop Operator (MVP).

Command-line interface for the AIDO agent. Run ``aido`` for the interactive
REPL, or ``aido "open firefox"`` for a one-shot command.
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
        description="AIDO — AI Desktop Operator: a local, open-source desktop assistant for Linux.",
    )
    parser.add_argument(
        "command",
        nargs="*",
        help="One-shot natural-language command (leave empty for interactive mode).",
    )
    parser.add_argument(
        "--model",
        metavar="PATH",
        help="Path to a .gguf model file (default: from config or ~/.aido/models).",
    )
    parser.add_argument(
        "--config",
        metavar="PATH",
        help="Path to a YAML config file (default: config/aido.yaml).",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="Automatically approve destructive tool calls (use with care).",
    )
    parser.add_argument(
        "--list-tools",
        action="store_true",
        help="Print the tools AIDO can use and exit.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Show tool calls as they happen.",
    )
    parser.add_argument(
        "--gui",
        action="store_true",
        help="Launch the Tkinter chat GUI instead of the terminal REPL.",
    )
    parser.add_argument(
        "--tray",
        action="store_true",
        help="Run in the system tray (needs the 'tray' extra: pip install \"aido[tray]\").",
    )
    parser.add_argument(
        "--voice",
        action="store_true",
        help="Use the microphone for input (needs the 'voice' extra: pip install \"aido[voice]\").",
    )
    parser.add_argument(
        "--voice-engine",
        choices=["sphinx", "google"],
        default="sphinx",
        help="Voice engine: 'sphinx' (offline, default) or 'google' (cloud, opt-in).",
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


def _repl(agent: Agent, assume_yes: bool, verbose: bool, voice: bool = False, voice_engine: str = "sphinx") -> int:
    if voice:
        import voice as voice_mod
    print(BANNER)
    if voice:
        print("🎤 Voice mode: speak after the prompt (engine: " + voice_engine + ").\n")
    else:
        print("Try: \"Open Firefox\", \"What's in my Downloads folder?\", or 'exit' to quit.\n")
    while True:
        if voice:
            print("🎤 Listening...")
            try:
                line = voice_mod.listen(engine=voice_engine)
            except utils.AidoError as exc:
                print(f"⚠️  {exc}")
                continue
            print(f"🎤 You: {line}")
        else:
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


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    try:
        config = utils.load_config(args.config)
    except utils.AidoError as exc:
        _print_error(str(exc))
        return 1

    utils.setup_logging(
        log_dir=config.get("logging", {}).get("dir"),
        level=config.get("logging", {}).get("level", "INFO"),
    )

    if args.list_tools:
        _print_tools()
        return 0

    try:
        model_path = utils.resolve_model_path(explicit=args.model, config=config)
        agent = Agent(model_path=str(model_path), config=config)
    except utils.AidoError as exc:
        _print_error(str(exc))
        return 1

    try:
        if args.gui:
            from gui import launch_gui

            launch_gui(agent, assume_yes=args.yes, verbose=args.verbose)
            return 0
        if args.tray:
            from tray import run_tray

            run_tray(agent, assume_yes=args.yes)
            return 0
        if args.command:
            question = " ".join(args.command)
            if args.voice:
                import voice as voice_mod

                try:
                    question = voice_mod.listen(engine=args.voice_engine)
                    print(f"🎤 {question}")
                except utils.AidoError as exc:
                    _print_error(str(exc))
                    return 1
            result = agent.chat(question, interactive=sys.stdin.isatty(), assume_yes=args.yes)
            if args.verbose:
                for call in result["tool_calls"]:
                    print(f"  ⚙️  {call.get('tool')} {call.get('arguments')}")
            print(result["answer"])
            return 0
        return _repl(agent, assume_yes=args.yes, verbose=args.verbose, voice=args.voice, voice_engine=args.voice_engine)
    except utils.AidoError as exc:
        _print_error(str(exc))
        return 1
    finally:
        agent.close()


if __name__ == "__main__":
    sys.exit(main())
