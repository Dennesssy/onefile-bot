#!/usr/bin/env python3
"""Groq tool-calling loop whose ONLY tools are read/write/append/edit on one assigned file.

nanobot (v0.0.92) always injects built-in tools (bash, edit, glob, webFetch, ...) into every
request, so it cannot be confined to a file. Here the request's `tools` array is built from the
four OneFile tools and nothing else, so the model has no way to reach any other file.

Usage: onefile_bot.py --file /abs/path "what to write" [--model openai/gpt-oss-120b] [--max-steps 12]
Needs GROQ_API_KEY in the environment.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from onefile_mcp import OneFile, tools as onefile_tools  # noqa: E402

GROQ = "https://api.groq.com/openai/v1/chat/completions"


MALFORMED_RETRIES = 5


def chat(model, messages, tools):
    """One completion. If the model emits a tool call Groq can't parse as JSON (tool_use_failed,
    common when writing a large file in one call), tell the model and retry, asking for smaller pieces."""
    for attempt in range(MALFORMED_RETRIES + 1):
        body = json.dumps({"model": model, "messages": messages, "temperature": 0.2,
                           "tools": tools, "tool_choice": "auto",
                           "max_tokens": 16000}).encode()  # without it Groq truncates long tool-call content
        req = urllib.request.Request(GROQ, data=body, headers={
            "Authorization": f"Bearer {os.environ['GROQ_API_KEY']}", "Content-Type": "application/json",
            "User-Agent": "onefile-bot/1.0"})
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                return json.loads(r.read())["choices"][0]["message"]
        except urllib.error.HTTPError as e:
            detail = e.read().decode()
            if e.code in (429, 503) and attempt < MALFORMED_RETRIES:
                wait = float(e.headers.get("retry-after") or 0) or 15 * (attempt + 1)
                print(f"[retry {attempt + 1}] Groq HTTP {e.code}; waiting {wait:.0f}s", file=sys.stderr)
                time.sleep(min(wait, 120))
                continue
            if e.code == 400 and "tool_use_failed" in detail and attempt < MALFORMED_RETRIES:
                print(f"[retry {attempt + 1}] model produced an invalid tool call; asking for smaller pieces",
                      file=sys.stderr)
                messages.append({"role": "user", "content":
                    "Your last tool call could not be parsed as JSON and was not executed. Retry with smaller "
                    "pieces: write_file a short skeleton first, then add one section at a time with edit_file. "
                    "Keep every JSON string properly escaped."})
                continue
            sys.exit(f"Groq HTTP {e.code}: {detail[:500]}")


def call(f, name, args):
    try:
        if name == "read_file":
            return f.read()
        if name == "write_file":
            return f.write(args["content"])
        if name == "append_file":
            return f.append(args["content"])
        if name == "edit_file":
            return f.edit(args["old_string"], args["new_string"])
        return f"error: unknown tool {name}; only read_file, write_file, append_file, edit_file exist"
    except (ValueError, KeyError, OSError) as e:
        return f"error: {e}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    ap.add_argument("prompt")
    ap.add_argument("--model", default="openai/gpt-oss-120b")
    ap.add_argument("--max-steps", type=int, default=12)
    ap.add_argument("--context", action="append", default=[],
                    help="read-only reference file whose text is included in the prompt (repeatable)")
    a = ap.parse_args()
    if not os.environ.get("GROQ_API_KEY"):
        sys.exit("GROQ_API_KEY not set")

    f = OneFile(a.file)
    tools = [{"type": "function", "function": {"name": t["name"], "description": t["description"],
                                               "parameters": t["inputSchema"]}} for t in onefile_tools(f.path)]
    reference = "".join(f"\n\n--- reference (read-only): {p} ---\n{open(p, encoding='utf-8').read()}" for p in a.context)
    messages = [
        {"role": "system", "content":
            f"You write and edit exactly one file: {f.path}\n"
            "Your only tools are read_file, write_file, append_file and edit_file; they always act on that file. "
            "Read the file first, make the requested change, then read it back to check it. "
            "To create a long file, write_file the first section, then append_file each further section in order; "
            "don't re-read the file between appends. "
            "Finish with a short summary of what you wrote. Do not ask questions."},
        {"role": "user", "content": a.prompt + reference},
    ]
    for step in range(a.max_steps):
        msg = chat(a.model, messages, tools)
        messages.append({k: v for k, v in msg.items() if k in ("role", "content", "tool_calls")})
        calls = msg.get("tool_calls") or []
        if not calls:
            print(msg.get("content") or "")
            return
        for c in calls:
            name = c["function"]["name"]
            try:
                args = json.loads(c["function"].get("arguments") or "{}")
            except json.JSONDecodeError:
                args = {}
            result = call(f, name, args)
            print(f"[step {step + 1}] {name} -> {result.splitlines()[0][:100] if result else ''}", file=sys.stderr)
            messages.append({"role": "tool", "tool_call_id": c["id"], "content": result})
    sys.exit(f"stopped after {a.max_steps} steps without a final answer")


if __name__ == "__main__":
    main()
