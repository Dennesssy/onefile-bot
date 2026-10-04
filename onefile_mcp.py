#!/usr/bin/env python3
"""MCP stdio server that exposes ONE file: read_file, write_file, append_file, edit_file.

The path is fixed at launch (--file); no tool accepts a path, so a model using this
server cannot touch any other file. Stdlib only.

Usage: python3 onefile_mcp.py --file /abs/path/to/File.swift
"""
import argparse
import json
import os
import sys

MAX_BYTES = 1_000_000


def parse_args():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", required=True)
    return ap.parse_args()


class OneFile:
    def __init__(self, path):
        self.path = os.path.realpath(path)  # resolve symlinks once, at launch
        if os.path.isdir(self.path):
            raise SystemExit(f"{self.path} is a directory")
        if not os.path.isdir(os.path.dirname(self.path)):
            raise SystemExit(f"parent directory of {self.path} does not exist")

    def read(self):
        if not os.path.exists(self.path):
            return f"(file {self.path} does not exist yet; use write_file to create it)"
        if os.path.getsize(self.path) > MAX_BYTES:
            raise ValueError("file is larger than 1 MB")
        with open(self.path, encoding="utf-8") as f:
            return f.read()

    def write(self, content):
        if len(content.encode()) > MAX_BYTES:
            raise ValueError("content is larger than 1 MB")
        tmp = self.path + ".onefile-tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp, self.path)  # atomic: never leaves a half-written file
        return f"wrote {len(content)} characters to {self.path}"

    def append(self, content):
        existing = self.read() if os.path.exists(self.path) else ""
        return self.write(existing + content).replace("wrote", "appended; now")

    def edit(self, old, new):
        text = self.read() if os.path.exists(self.path) else None
        if text is None:
            raise ValueError("file does not exist yet; use write_file first")
        count = text.count(old)
        if not old or count != 1:
            raise ValueError(f"old_string must occur exactly once (found {count} times)")
        return self.write(text.replace(old, new, 1)).replace("wrote", "edited; now")


def tools(path):
    return [
        {"name": "read_file", "description": f"Read the assigned file ({path}). Takes no arguments.",
         "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False}},
        {"name": "write_file", "description": f"Create or completely replace the assigned file ({path}).",
         "inputSchema": {"type": "object", "properties": {"content": {"type": "string"}},
                         "required": ["content"], "additionalProperties": False}},
        {"name": "append_file",
         "description": f"Append text to the end of the assigned file ({path}), creating it if needed. "
                        "Use this to build a long file in chunks.",
         "inputSchema": {"type": "object", "properties": {"content": {"type": "string"}},
                         "required": ["content"], "additionalProperties": False}},
        {"name": "edit_file",
         "description": f"Replace one exact, unique occurrence of old_string with new_string in the assigned file ({path}).",
         "inputSchema": {"type": "object",
                         "properties": {"old_string": {"type": "string"}, "new_string": {"type": "string"}},
                         "required": ["old_string", "new_string"], "additionalProperties": False}},
    ]


def handle(msg, f):
    method, params = msg.get("method"), msg.get("params") or {}
    if method == "initialize":
        return {"protocolVersion": params.get("protocolVersion", "2025-06-18"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "onefile", "version": "1.0"},
                "instructions": f"You can only access one file: {f.path}"}
    if method == "tools/list":
        return {"tools": tools(f.path)}
    if method == "tools/call":
        name, args = params.get("name"), params.get("arguments") or {}
        try:
            if name == "read_file":
                text = f.read()
            elif name == "write_file":
                text = f.write(args["content"])
            elif name == "append_file":
                text = f.append(args["content"])
            elif name == "edit_file":
                text = f.edit(args["old_string"], args["new_string"])
            else:
                raise ValueError(f"unknown tool {name}")
            return {"content": [{"type": "text", "text": text}], "isError": False}
        except (ValueError, KeyError, OSError) as e:
            return {"content": [{"type": "text", "text": f"error: {e}"}], "isError": True}
    if method == "ping":
        return {}
    raise LookupError(method)


def main():
    f = OneFile(parse_args().file)
    for line in sys.stdin:
        if not line.strip():
            continue
        msg = json.loads(line)
        if "id" not in msg:  # notification (e.g. notifications/initialized)
            continue
        try:
            reply = {"jsonrpc": "2.0", "id": msg["id"], "result": handle(msg, f)}
        except LookupError as e:
            reply = {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": f"method not found: {e}"}}
        sys.stdout.write(json.dumps(reply) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
