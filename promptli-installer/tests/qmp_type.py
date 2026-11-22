#!/usr/bin/env python3
"""Drive a QEMU guest through QMP: type text on the VGA console.

Usage: qmp_type.py SOCKET TEXT [TEXT2 ...]
Each argument is typed followed by Enter.
"""
import json
import socket
import sys
import time

QKEY = {
    "a": "a", "b": "b", "c": "c", "d": "d", "e": "e", "f": "f", "g": "g",
    "h": "h", "i": "i", "j": "j", "k": "k", "l": "l", "m": "m", "n": "n",
    "o": "o", "p": "p", "q": "q", "r": "r", "s": "s", "t": "t", "u": "u",
    "v": "v", "w": "w", "x": "x", "y": "y", "z": "z",
    "0": "0", "1": "1", "2": "2", "3": "3", "4": "4", "5": "5", "6": "6",
    "7": "7", "8": "8", "9": "9",
    " ": "spc", "-": "minus", ".": "dot", "/": "slash", "=": "equal",
    "\n": "ret", ",": "comma", ";": "semicolon", "'": "apostrophe",
    "_": "shift-minus", "&": "shift-7", "|": "shift-backslash",
    "!": "shift-1", ":": "shift-semicolon", "@": "shift-2",
    "+": "shift-equal", "*": "shift-8", "(": "shift-9", ")": "shift-0",
    "?": "shift-slash", "~": "shift-grave_accents", "$": "shift-4",
    "%": "shift-5", "#": "shift-3", "^": "shift-6",
    '"': "shift-apostrophe", "<": "shift-comma", ">": "shift-dot",
    "{": "shift-bracket_left", "}": "shift-bracket_right",
    "[": "bracket_left", "]": "bracket_right", "\\": "backslash",
}


def key_for(ch):
    if ch in QKEY:
        return QKEY[ch]
    if ch.isupper():
        return "shift-" + ch.lower()
    return None


def send_keys(s, keys):
    # QEMU send-key presses ALL listed keys together (released in reverse),
    # so shift combinations must go out one keystroke at a time.
    payload = []
    for k in keys:
        if k.startswith("shift-"):
            payload.append({"type": "qcode", "data": "shift"})
            payload.append({"type": "qcode", "data": k[6:]})
        else:
            payload.append({"type": "qcode", "data": k})
    s.sendall(
        json.dumps({"execute": "send-key", "arguments": {"keys": payload}}).encode()
        + b"\n"
    )
    s.recv(65536)


def type_text(s, text, delay=0.012):
    for c in text:
        k = key_for(c)
        if k is None:
            raise ValueError(f"unsupported char {c!r} in {text!r}")
        send_keys(s, [k])
        time.sleep(delay)


def main():
    sock_path, texts = sys.argv[1], sys.argv[2:]
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    s.settimeout(5)
    s.recv(65536)  # greeting
    s.sendall(json.dumps({"execute": "qmp_capabilities"}).encode() + b"\n")
    s.recv(65536)
    for t in texts:
        type_text(s, t, delay=0.008)
        send_keys(s, ["ret"])
        time.sleep(0.5)
    print("typed:", texts)


if __name__ == "__main__":
    main()
