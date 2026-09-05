"""Unit tests for shared helpers (utils)."""

import utils

# -- formatting -------------------------------------------------------------

def test_human_size():
    assert utils.human_size(0) == "0B"
    assert utils.human_size(4 * 1024) == "4.0KB"
    assert utils.human_size(2457600) == "2.3MB"
    assert utils.human_size(None) == "unknown"


def test_truncate():
    assert utils.truncate("short") == "short"
    assert "truncated" in utils.truncate("x" * 5000)


# -- JSON extraction ----------------------------------------------------------

def test_extract_json_valid():
    assert utils.extract_json('{"tool": "list_files", "arguments": {}}') == {
        "tool": "list_files",
        "arguments": {},
    }


def test_extract_json_inside_prose():
    text = 'Sure! I will use {"tool": "launch_app", "arguments": {"command": "firefox"}} now.'
    assert utils.extract_json(text) == {"tool": "launch_app", "arguments": {"command": "firefox"}}


def test_extract_json_strips_code_fences():
    text = 'Here is the plan:\n```json\n{"answer": "hi"}\n```\nHope that helps.'
    assert utils.extract_json(text) == {"answer": "hi"}


def test_extract_json_repairs_trailing_commas():
    assert utils.extract_json('{"a": 1, "b": [1, 2,],}') == {"a": 1, "b": [1, 2]}


def test_extract_json_repairs_single_quotes():
    text = "{'tool': 'launch_app', 'arguments': {'command': 'firefox'}}"
    assert utils.extract_json(text) == {
        "tool": "launch_app",
        "arguments": {"command": "firefox"},
    }


def test_extract_json_repairs_unquoted_keys():
    assert utils.extract_json('{tool: "list_files", arguments: {}}') == {
        "tool": "list_files",
        "arguments": {},
    }


def test_extract_json_repairs_unterminated_object():
    text = '{"tool": "list_files", "arguments": {"path": "."'
    assert utils.extract_json(text) == {"tool": "list_files", "arguments": {"path": "."}}


def test_extract_json_returns_none_for_plain_text():
    assert utils.extract_json("Just a plain answer, no JSON here.") is None
    assert utils.extract_json("") is None
    assert utils.extract_json(None) is None


# -- paths & safety ------------------------------------------------------------

def test_expand_path_expands_home(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    assert utils.expand_path("~/docs") == tmp_path / "docs"


def test_restrict_to_allowed_permits_inside(tmp_path):
    allowed = [str(tmp_path / "safe")]
    (tmp_path / "safe").mkdir()
    assert utils.restrict_to_allowed(str(tmp_path / "safe" / "file.txt"), allowed) == tmp_path / "safe" / "file.txt"


def test_restrict_to_allowed_denies_outside(tmp_path):
    allowed = [str(tmp_path / "safe")]
    (tmp_path / "safe").mkdir()
    (tmp_path / "outside").mkdir()
    try:
        utils.restrict_to_allowed(str(tmp_path / "outside"), allowed)
    except utils.AidoError as exc:
        assert "Access denied" in str(exc)
    else:
        raise AssertionError("expected AidoError for path outside allowed dirs")


def test_restrict_to_allowed_without_rules_allows_everything(tmp_path):
    assert utils.restrict_to_allowed(str(tmp_path)) == tmp_path


def test_restrict_to_allowed_ignores_null_entries(tmp_path):
    """Regression test: a bare '~' in YAML parses as null (None) entries."""
    allowed = [None, str(tmp_path)]
    (tmp_path / "file.txt").write_text("hi")
    assert utils.restrict_to_allowed(str(tmp_path / "file.txt"), allowed) == tmp_path / "file.txt"


def test_restrict_to_allowed_none_entry_raises_aido_error(tmp_path):
    (tmp_path / "outside").mkdir()
    try:
        utils.restrict_to_allowed(str(tmp_path / "outside"), [None])
    except utils.AidoError as exc:
        assert "Access denied" in str(exc)
    else:
        raise AssertionError("expected AidoError when no usable allowed dir remains")


# -- configuration -------------------------------------------------------------

def test_merge_configs_nested():
    defaults = {"a": {"x": 1, "y": 2}, "b": 3}
    overrides = {"a": {"y": 20}}
    assert utils.merge_configs(defaults, overrides) == {"a": {"x": 1, "y": 20}, "b": 3}


def test_load_config_returns_defaults_when_missing(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)  # no config/aido.yaml here
    monkeypatch.delenv("AIDO_CONFIG", raising=False)
    config = utils.load_config()
    assert config["model"]["context_size"] == 2048
    assert config["safety"]["allowed_dirs"] == ["~"]


def test_shipped_config_parses_allowed_dirs_as_strings():
    """Regression test: a bare '~' in YAML parses as null, not the home dir."""
    from pathlib import Path

    config = utils.load_config(str(Path(__file__).resolve().parent.parent / "config" / "aido.yaml"))
    assert config["safety"]["allowed_dirs"] == ["~"]


# -- confirmation -----------------------------------------------------------------

def test_ask_confirmation_assume_yes():
    assert utils.ask_confirmation("ok?", assume_yes=True, interactive=False) is True


def test_ask_confirmation_non_interactive_defaults_to_no():
    assert utils.ask_confirmation("ok?", interactive=False) is False


def test_ask_confirmation_reads_yes(monkeypatch):
    monkeypatch.setattr("builtins.input", lambda _: "y")
    assert utils.ask_confirmation("ok?", interactive=True) is True


def test_ask_confirmation_reads_no(monkeypatch):
    monkeypatch.setattr("builtins.input", lambda _: "n")
    assert utils.ask_confirmation("ok?", interactive=True) is False
