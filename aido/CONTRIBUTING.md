# Contributing to AIDO

Thanks for your interest in contributing! AIDO is a small, MIT-licensed
project and we welcome improvements of any size.

## Ground rules

- All code you contribute is released under the **MIT license**.
- Keep dependencies permissively licensed (MIT/Apache-2.0/BSD) — no GPL
  runtime dependencies.
- Respect the privacy guarantees: no telemetry, no external AI APIs,
  processing stays local.
- New tools must return JSON-serializable dicts and raise `utils.AidoError`
  with user-friendly messages (never print or prompt from inside a tool —
  the agent layer handles that).

## Getting started

```bash
python3 -m venv venv && source venv/bin/activate
pip install -e ".[dev]"
pytest tests/          # everything should pass before you start
```

## Adding a tool

1. Implement the function in `src/tools.py` following the existing style
   (lazy imports for heavy dependencies, `_resolve()` for path safety).
2. Add its entry to `TOOL_REGISTRY` (name, description, parameters,
   `dangerous` flag) and to `TOOL_FUNCTIONS`. The built-in assertion keeps
   the two in sync.
3. If it takes file paths, give it an `allowed_dirs` parameter and bind it
   in `agent.build_tools()`.
4. Add unit tests in `tests/test_tools.py`.

## Style

- Python 3.10+ compatible, standard library preferred.
- Follow the existing docstring and naming conventions.
- Run `pytest tests/` and `ruff check src tests setup.py` before submitting
  a pull request — CI does both on every push/PR.
