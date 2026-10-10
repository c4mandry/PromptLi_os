"""Unit tests for all AIDO tools.

File, config, process and web tools are tested on any platform; window tools
are exercised on Linux with wmctrl installed and error paths are tested
everywhere.
"""

import configparser
import http.server
import json
import os
import shutil
import subprocess
import sys
import threading
import time

import pytest

import tools
import utils

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def sandbox(tmp_path):
    """A small fake home directory tree."""
    (tmp_path / "report.pdf").write_bytes(b"x" * 2457600)  # ~2.3MB
    (tmp_path / "image.png").write_bytes(b"y" * 1024)
    (tmp_path / "Projects").mkdir()
    (tmp_path / ".hidden").write_text("secret")
    return tmp_path


class _TestHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/file"):
            payload = b"A" * 12345
            content_type = "application/octet-stream"
        elif self.path == "/page":
            payload = b"<html><body><p>Hello AIDO test page</p></body></html>"
            content_type = "text/html"
        else:
            payload = b"not found"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format: str, *args: object) -> None:  # silence request logs
        pass


@pytest.fixture
def http_url():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _TestHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_port}"
    server.shutdown()
    server.server_close()


# ---------------------------------------------------------------------------
# File tools
# ---------------------------------------------------------------------------


def test_list_files_metadata(sandbox):
    result = tools.list_files(path=str(sandbox))
    assert result["count"] == 3  # report.pdf, image.png, Projects
    names = {entry["name"]: entry for entry in result["entries"]}
    assert names["report.pdf"]["type"] == "file"
    assert names["report.pdf"]["size"] == 2457600
    assert names["report.pdf"]["modified"]
    assert names["Projects"]["type"] == "directory"
    assert names["Projects"]["size"] is None


def test_list_files_hidden(sandbox):
    assert tools.list_files(path=str(sandbox))["count"] == 3
    assert tools.list_files(path=str(sandbox), include_hidden=True)["count"] == 4


def test_list_files_not_a_directory(tmp_path):
    (tmp_path / "plain.txt").write_text("hi")
    with pytest.raises(utils.AidoError, match="Not a directory"):
        tools.list_files(path=str(tmp_path / "plain.txt"))


def test_find_files_by_glob(sandbox):
    (sandbox / "Projects" / "notes.txt").write_text("hi")
    (sandbox / "Projects" / "todo.txt").write_text("hi")
    (sandbox / "Projects" / "sub").mkdir()
    (sandbox / "Projects" / "sub" / "notes.md").write_text("hi")
    result = tools.find_files(root=str(sandbox), pattern="*.txt")
    assert set(result["matches"]) == {"Projects/notes.txt", "Projects/todo.txt"}


def test_find_files_by_name(sandbox):
    result = tools.find_files(root=str(sandbox), name="report")
    assert result["matches"] == ["report.pdf"]


def test_find_files_skips_hidden(sandbox):
    result = tools.find_files(root=str(sandbox), pattern="*")
    assert ".hidden" not in result["matches"]


def test_file_info(sandbox):
    result = tools.file_info(path=str(sandbox / "report.pdf"))
    assert result["type"] == "file"
    assert result["size"] == 2457600
    assert result["permissions"].startswith("0o")
    assert result["modified"]


def test_file_info_missing(tmp_path):
    with pytest.raises(utils.AidoError, match="not found"):
        tools.file_info(path=str(tmp_path / "missing.txt"))


def test_allowed_dirs_restriction(tmp_path):
    allowed = [str(tmp_path / "safe")]
    (tmp_path / "safe").mkdir()
    (tmp_path / "outside").mkdir()
    with pytest.raises(utils.AidoError, match="Access denied"):
        tools.list_files(path=str(tmp_path / "outside"), allowed_dirs=allowed)
    assert tools.list_files(path=str(tmp_path / "safe"), allowed_dirs=allowed)["count"] == 0


# ---------------------------------------------------------------------------
# Config tools
# ---------------------------------------------------------------------------


def test_config_json_roundtrip(sandbox):
    path = sandbox / "settings.json"
    path.write_text(json.dumps({"theme": "light", "window": {"width": 800}}))
    result = tools.edit_config(path=str(path), changes={"theme": "dark", "window.width": 1024})
    assert result["status"] == "updated"
    assert result["backup"] and os.path.isfile(result["backup"])
    assert result["changes"] == [
        {"key": "theme", "old": "light", "new": "dark"},
        {"key": "window.width", "old": 800, "new": 1024},
    ]
    data = json.loads(path.read_text())
    assert data["theme"] == "dark"
    assert data["window"]["width"] == 1024


def test_config_yaml_roundtrip(sandbox):
    path = sandbox / "config.yaml"
    path.write_text("theme: light\nwindow:\n  width: 800\n")
    result = tools.edit_config(path=str(path), changes={"theme": "dark"})
    assert result["format"] == "yaml"
    import yaml

    data = yaml.safe_load(path.read_text())
    assert data["theme"] == "dark"
    assert data["window"]["width"] == 800


def test_config_ini_roundtrip(sandbox):
    path = sandbox / "app.ini"
    path.write_text("[ui]\ntheme = light\n\n[window]\nwidth = 800\n")
    result = tools.edit_config(path=str(path), changes={"ui.theme": "dark", "ui.scale": 2})
    assert result["format"] == "ini"
    parser = configparser.ConfigParser()
    parser.read(path)
    assert parser.get("ui", "theme") == "dark"
    assert parser.get("ui", "scale") == "2"
    assert parser.get("window", "width") == "800"


def test_config_backup_and_restore(sandbox):
    path = sandbox / "settings.json"
    path.write_text(json.dumps({"theme": "light"}))
    backup = tools.backup_config(path=str(path))
    tools.edit_config(path=str(path), changes={"theme": "dark"})
    assert json.loads(path.read_text())["theme"] == "dark"
    tools.restore_config(path=str(path), backup=backup["backup"])
    assert json.loads(path.read_text())["theme"] == "light"


def test_config_edit_without_backup(sandbox):
    path = sandbox / "settings.json"
    path.write_text(json.dumps({"theme": "light"}))
    result = tools.edit_config(path=str(path), changes={"theme": "dark"}, auto_backup=False)
    assert result["backup"] is None
    assert len(list(sandbox.glob("*.backup-*"))) == 0


def test_config_unknown_format(sandbox):
    path = sandbox / "config.txt"
    path.write_text("hello")
    with pytest.raises(utils.AidoError, match="Unsupported config format"):
        tools.read_config(path=str(path))


def test_config_missing_file(tmp_path):
    with pytest.raises(utils.AidoError, match="not found"):
        tools.read_config(path=str(tmp_path / "none.json"))


def test_read_config_returns_data(sandbox):
    path = sandbox / "settings.json"
    path.write_text(json.dumps({"theme": "light"}))
    result = tools.read_config(path=str(path))
    assert result["format"] == "json"
    assert result["data"] == {"theme": "light"}


# ---------------------------------------------------------------------------
# Process tools
# ---------------------------------------------------------------------------


def _is_alive(pid):
    """Check whether pid exists and is not a zombie."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    proc = subprocess.run(
        ["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True, check=False
    )
    return proc.returncode == 0 and "Z" not in (proc.stdout or "")


def _wait_until_gone(pid, timeout=5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not _is_alive(pid):
            return
        time.sleep(0.05)
    pytest.fail(f"process {pid} still alive after {timeout}s")


def test_launch_and_terminate_process():
    result = tools.launch_app(command="sleep 30")
    pid = result["pid"]
    assert result["status"] == "running"
    assert _is_alive(pid)
    try:
        tools.terminate_process(pid=pid)
        _wait_until_gone(pid)
    finally:
        if _is_alive(pid):
            tools.terminate_process(pid=pid, force=True)


def test_list_processes_filters():
    launched = tools.launch_app(command="sleep 30")
    try:
        listing = tools.list_processes(filter_text="sleep 30")
        pids = [p["pid"] for p in listing["processes"]]
        assert launched["pid"] in pids
    finally:
        if _is_alive(launched["pid"]):
            tools.terminate_process(pid=launched["pid"], force=True)


def test_terminate_unknown_process():
    with pytest.raises(utils.AidoError, match="No process"):
        tools.terminate_process(pid=999999)


# ---------------------------------------------------------------------------
# Window tools (error paths run everywhere; live tests only on Linux)
# ---------------------------------------------------------------------------


def test_system_info():
    result = tools.system_info()
    assert result["cpu_count"] >= 1
    assert result["disk_usage"]["total"] > 0
    assert result["disk_usage"]["free"] > 0
    assert "platform" in result


def test_screenshot_requires_tool(monkeypatch, tmp_path):
    monkeypatch.setattr(tools.sys, "platform", "linux")
    monkeypatch.setattr(tools.shutil, "which", lambda _: None)
    with pytest.raises(utils.AidoError, match="screenshot tool"):
        tools.screenshot(destination=str(tmp_path / "shot.png"))


@pytest.mark.skipif(
    sys.platform != "linux" or not (shutil.which("scrot") or shutil.which("import")),
    reason="requires Linux with scrot or ImageMagick",
)
def test_screenshot_live(tmp_path):
    result = tools.screenshot(destination=str(tmp_path / "shot.png"))
    assert result["status"] == "captured"
    assert (tmp_path / "shot.png").stat().st_size > 0


def test_window_tools_require_linux(monkeypatch):
    monkeypatch.setattr(tools.sys, "platform", "darwin")
    with pytest.raises(utils.AidoError, match="requires Linux"):
        tools.list_windows()


def test_window_tools_require_wmctrl(monkeypatch):
    monkeypatch.setattr(tools.sys, "platform", "linux")
    monkeypatch.setattr(tools.shutil, "which", lambda _: None)
    with pytest.raises(utils.AidoError, match="wmctrl is not installed"):
        tools.list_windows()


@pytest.mark.skipif(
    sys.platform != "linux" or shutil.which("wmctrl") is None,
    reason="requires Linux with wmctrl installed",
)
def test_list_windows_live():
    result = tools.list_windows()
    assert "windows" in result
    assert isinstance(result["count"], int)


@pytest.mark.skipif(
    sys.platform != "linux" or shutil.which("wmctrl") is None,
    reason="requires Linux with wmctrl installed",
)
def test_get_screen_size_live():
    result = tools.get_screen_size()
    assert result["width"] > 0
    assert result["height"] > 0


# ---------------------------------------------------------------------------
# Web tools (against a local HTTP server — no external network)
# ---------------------------------------------------------------------------


def test_fetch_url(http_url):
    result = tools.fetch_url(url=http_url + "/page")
    assert result["status"] == 200
    assert "Hello AIDO test page" in result["text"]
    assert result["content_type"] == "text/html"


def test_fetch_url_http_error(http_url):
    with pytest.raises(utils.AidoError):
        tools.fetch_url(url=http_url + "/missing", timeout=5)


def test_download_file_to_destination(http_url, tmp_path):
    dest = tmp_path / "out.bin"
    result = tools.download_file(url=http_url + "/file", destination=str(dest))
    assert result["status"] == "complete"
    assert result["size"] == 12345
    assert dest.read_bytes() == b"A" * 12345
    assert not (tmp_path / "out.bin.part").exists()


def test_download_file_default_destination(http_url, tmp_path):
    result = tools.download_file(url=http_url + "/file.bin", downloads_dir=str(tmp_path))
    assert result["destination"] == str(tmp_path / "file.bin")
    assert (tmp_path / "file.bin").read_bytes() == b"A" * 12345


def test_download_file_http_error(http_url, tmp_path):
    with pytest.raises(utils.AidoError):
        tools.download_file(url=http_url + "/missing", destination=str(tmp_path / "x.bin"))
    assert not (tmp_path / "x.bin").exists()
