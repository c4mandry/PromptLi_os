#!/usr/bin/env python3
"""
promptLi Daemon — runs with elevated privileges for system command execution.
Communicates via Unix socket with the assistant app.
"""

import json
import os
import subprocess
import sys
import threading
from pathlib import Path
from socket import AF_UNIX, SOCK_STREAM, socket

SOCKET_PATH = "/tmp/promptli-daemon.sock"
CONFIG_DIR = Path.home() / ".config" / "promptli"
LOG_FILE = CONFIG_DIR / "daemon_log.json"

DANGEROUS_KEYWORDS = [
    "rm -rf /", "mkfs.", "dd if=", "> /dev/sd",
    "chmod 777 /", ":(){ :|:& };:", "rm -rf --no-preserve-root",
]


def is_dangerous(command: str) -> bool:
    cmd_lower = command.lower().strip()
    for kw in DANGEROUS_KEYWORDS:
        if kw.lower() in cmd_lower:
            return True
    return False


def execute_command(command: str, timeout: int = 120) -> dict:
    """Execute a shell command and return results."""
    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return {
            "success": result.returncode == 0,
            "returncode": result.returncode,
            "stdout": result.stdout.strip()[-5000:],
            "stderr": result.stderr.strip()[-5000:],
        }
    except subprocess.TimeoutExpired:
        return {"success": False, "error": "Command timed out"}
    except Exception as e:
        return {"success": False, "error": str(e)}


def handle_client(conn: socket):
    """Handle a client connection."""
    try:
        data = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break

        request = json.loads(data.decode().strip())

        command = request.get("command", "")
        require_confirmation = request.get("require_confirmation", True)
        force = request.get("force", False)

        # Safety check
        if is_dangerous(command) and not force:
            response = {
                "success": False,
                "error": "DANGEROUS_COMMAND",
                "message": f"Command blocked: '{command}' is potentially dangerous.",
            }
        else:
            response = execute_command(command)
            response["command"] = command

        conn.sendall(json.dumps(response).encode() + b"\n")
    except json.JSONDecodeError:
        conn.sendall(json.dumps({"success": False, "error": "Invalid JSON"}).encode() + b"\n")
    except Exception as e:
        conn.sendall(json.dumps({"success": False, "error": str(e)}).encode() + b"\n")
    finally:
        conn.close()


def main():
    # Clean up stale socket
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)

    server = socket(AF_UNIX, SOCK_STREAM)
    server.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o660)  # Restrict access
    server.listen(5)

    print(f"[promptLi Daemon] Listening on {SOCKET_PATH}")

    try:
        while True:
            conn, _ = server.accept()
            thread = threading.Thread(target=handle_client, args=(conn,), daemon=True)
            thread.start()
    except KeyboardInterrupt:
        print("\n[promptLi Daemon] Shutting down...")
    finally:
        server.close()
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)


if __name__ == "__main__":
    main()
