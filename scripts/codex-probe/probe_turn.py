#!/usr/bin/env python3
"""Probe a real inference turn: ephemeral thread, structured output, streaming deltas."""
import json, subprocess, threading, time

proc = subprocess.Popen(
    ["codex", "app-server"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    text=True, bufsize=1,
)

responses = {}
events = []

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
            events.append(msg)

threading.Thread(target=reader, daemon=True).start()

def send(msg):
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()

def wait_for(rid, timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if rid in responses:
            return responses[rid]
        time.sleep(0.05)
    return None

send({"method": "initialize", "id": 0, "params": {"clientInfo": {"name": "orttaai_probe", "title": "Orttaai Probe", "version": "0.0.1"}}})
wait_for(0)
send({"method": "initialized", "params": {}})

# Try ephemeral thread (not persisted to user's codex history)
send({"method": "thread/start", "id": 1, "params": {
    "model": "gpt-5.4-mini",
    "cwd": "/tmp",
    "approvalPolicy": "never",
    "sandbox": "read-only",
    "ephemeral": True,
    "serviceName": "orttaai",
}})
r = wait_for(1)
print("== thread/start ==")
print(json.dumps(r, indent=2)[:800])
if not r or "error" in r:
    # retry without ephemeral
    send({"method": "thread/start", "id": 11, "params": {
        "model": "gpt-5.4-mini", "cwd": "/tmp",
        "approvalPolicy": "never", "sandbox": "read-only",
    }})
    r = wait_for(11)
    print("== thread/start (retry, no ephemeral) ==")
    print(json.dumps(r, indent=2)[:800])

thread_id = r["result"]["thread"]["id"]

schema = {
    "type": "object",
    "properties": {
        "themes": {"type": "array", "items": {"type": "string"}},
        "sentiment": {"type": "string", "enum": ["positive", "neutral", "negative"]},
        "summary": {"type": "string"},
    },
    "required": ["themes", "sentiment", "summary"],
    "additionalProperties": False,
}

t0 = time.time()
send({"method": "turn/start", "id": 2, "params": {
    "threadId": thread_id,
    "input": [{"type": "text", "text": "Analyze this dictation transcript and respond ONLY with the JSON: 'Today I spoke with the team about the quarterly launch. I am worried we are behind on the marketing assets, but the engineering side looks solid. Need to follow up with Sarah about the budget.'"}],
    "outputSchema": schema,
}})
r = wait_for(2)
print("== turn/start ==")
print(json.dumps(r, indent=2)[:400])

# Wait for turn/completed
deadline = time.time() + 120
completed = None
while time.time() < deadline and completed is None:
    for e in events:
        if e.get("method") == "turn/completed":
            completed = e
            break
    time.sleep(0.2)

print(f"== elapsed: {time.time()-t0:.1f}s ==")
delta_count = 0
agent_text = ""
for e in events:
    m = e.get("method")
    if m == "item/agentMessage/delta":
        delta_count += 1
    if m == "item/completed" and e["params"]["item"].get("type") == "agentMessage":
        agent_text = e["params"]["item"].get("text", "")

print(f"== agentMessage deltas: {delta_count} ==")
print("== final agentMessage ==")
print(agent_text[:800])
print("== turn/completed ==")
print(json.dumps(completed, indent=2)[:600] if completed else "TIMED OUT")
print("== event methods seen ==")
print(sorted(set(e.get("method") for e in events)))
proc.terminate()
