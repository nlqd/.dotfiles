#!/usr/bin/env python3
"""Telnet helper for DrayTek routers. Runs commands and prints output delimited by === cmd === markers."""

import os
import socket
import sys
import time

def telnet_session(host, user, password, commands, timeout=8):
    s = socket.create_connection((host, 23), timeout=timeout)
    s.settimeout(2)
    buf = b""

    def read_until(markers, t=timeout):
        nonlocal buf
        if isinstance(markers, bytes):
            markers = [markers]
        end = time.time() + t
        while time.time() < end:
            try:
                chunk = s.recv(4096)
                if not chunk:
                    break
                # strip telnet IAC negotiation sequences
                cleaned = b""
                i = 0
                while i < len(chunk):
                    if chunk[i:i+1] == b'\xff' and i + 2 < len(chunk):
                        i += 3
                    else:
                        cleaned += chunk[i:i+1]
                        i += 1
                buf += cleaned
                for m in markers:
                    if m in buf:
                        result = buf
                        buf = b""
                        return result.decode("ascii", errors="replace")
            except socket.timeout:
                continue
            except OSError:
                break
        result = buf
        buf = b""
        return result.decode("ascii", errors="replace")

    # wait for Account: prompt
    read_until(b"Account:")
    s.sendall(user.encode() + b"\r\n")

    # might get Password: prompt or go straight to >
    out = read_until([b">", b"Password:"], 5)
    if "Password:" in out or "Password" in out:
        s.sendall(password.encode() + b"\r\n")
        out = read_until(b">", 5)
        if "Bad password" in out or "Bye" in out:
            print("ERROR: bad password", file=sys.stderr)
            s.close()
            sys.exit(1)

    for cmd in commands:
        print(f"=== {cmd} ===")
        s.sendall(cmd.encode() + b"\r\n")
        full_out = ""
        while True:
            out = read_until([b">", b"DrayTek>", b"--- MORE ---"], 5)
            full_out += out
            if b"--- MORE ---" in out.encode() if isinstance(out, str) else b"--- MORE ---" in out:
                s.sendall(b"q")
                time.sleep(0.3)
                # drain leftover after pressing q
                try:
                    leftover = s.recv(4096).decode("ascii", errors="replace")
                    full_out += leftover
                except socket.timeout:
                    pass
                break
            else:
                break
        lines = full_out.splitlines()
        for line in lines:
            line = line.rstrip("\r")
            stripped = line.strip()
            if not stripped:
                continue
            if stripped == cmd or (stripped.endswith(">") and len(stripped) < 15):
                continue
            if "--- MORE ---" in stripped:
                continue
            print(line)

    s.sendall(b"exit\r\n")
    s.close()

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print(f"usage: ROUTER_PASS=xxx {sys.argv[0]} HOST USER CMD [CMD...]", file=sys.stderr)
        sys.exit(1)
    host = sys.argv[1]
    user = sys.argv[2]
    password = os.environ.get("ROUTER_PASS", "")
    commands = sys.argv[3:]
    telnet_session(host, user, password, commands)
