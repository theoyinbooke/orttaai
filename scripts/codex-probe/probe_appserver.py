#!/usr/bin/env python3
"""Probe codex app-server over stdio: initialize, account/read, model/list."""
import json, subprocess, sys, threading, time

proc = subprocess.Popen(
    ["codex", "app-server"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    text=True, bufsize=1,
)

responses = {}
notifications = []

def reader():
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "id" in msg and ("result" in msg or "error" in msg):
            responses[msg["id"]] = msg
        else:
            notifications.append(msg)

t = threading.Thread(target=reader, daemon=True)
t.start()

def send(msg):
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()

def wait_for(rid, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if rid in responses:
            return responses[rid]
        time.sleep(0.05)
    return None

send({"method": "initialize", "id": 0, "params": {"clientInfo": {"name": "orttaai_probe", "title": "Orttaai Probe", "version": "0.0.1"}}})
r = wait_for(0)
print("== initialize ==")
print(json.dumps(r, indent=2)[:1500])

send({"method": "initialized", "params": {}})

send({"method": "account/read", "id": 1, "params": {"refreshToken": False}})
r = wait_for(1)
print("== account/read ==")
print(json.dumps(r, indent=2)[:1500])

send({"method": "model/list", "id": 2, "params": {"limit": 50}})
r = wait_for(2)
print("== model/list ==")
print(json.dumps(r, indent=2)[:4000])

send({"method": "account/rateLimits/read", "id": 3})
r = wait_for(3)
print("== account/rateLimits/read ==")
print(json.dumps(r, indent=2)[:1200])

proc.terminate()
print("== notifications seen ==")
for n in notifications[:10]:
    print(json.dumps(n)[:300])
