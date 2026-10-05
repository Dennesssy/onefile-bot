#!/usr/bin/env python3
"""Fan out one onefile-bot per file listed in a file-tree CSV.

Each bot may write only its own file (onefile_bot.py enforces that). The dispatcher decides
which file each bot gets, what it is told (the file's CSV row and its folder's row), and which
existing files it may read as --context. Files are processed in dependency waves so later
files can see earlier ones. Existing files are skipped unless --overwrite.

CSV columns: path,name,type,purpose,requirement,layer,plane,platform,status
(`path` relative to --root; produce it from a lvl-based tree with tree_to_paths()).

Usage:
  delegate.py --tree tree.csv --root REPO --wave 1 [--jobs 4] [--model qwen/qwen3.8-27b] [--dry-run]
  delegate.py --tree tree.csv --root REPO --wave all
"""
import argparse
import concurrent.futures as cf
import csv
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MAX_CONTEXT_FILES = 5
MAX_CONTEXT_BYTES = 60_000

# (wave number, name, predicate on relative path)
WAVES = [
    (1, "contracts", lambda p: p.startswith("proto/")),
    (2, "data and config", lambda p: p.startswith(("db/", "config/"))),
    (3, "core library", lambda p: p.startswith("Sources/AgenticGatewayCore/")),
    (4, "server, CLI, SDK", lambda p: p.startswith("Sources/")),
    (5, "execution node", lambda p: p.startswith("ExecutionNode/")),
    (6, "tests", lambda p: p.startswith("Tests/")),
    (7, "deploy, tooling, integrations, clients", lambda p: p.startswith(
        ("docker/", "deploy/", "scripts/", "integrations/", "clients/"))),
    (8, "docs and top-level", lambda p: True),
]

JS_ISMS = ("Temporal", "BigInt", "Iterator Chunking", "JSON Source Text Access", "Async Stack Traces")


def wave_of(path):
    for n, _, pred in WAVES:
        if pred(path):
            return n
    return WAVES[-1][0]


def load(tree):
    with open(tree, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def context_for(row, rows, root):
    """Read-only reference files: the package manifest and common contract for code, plus up to a
    few existing siblings in the same folder so names and style stay consistent."""
    path = row["path"]
    ext = os.path.splitext(path)[1]
    picks = []
    if ext == ".swift":
        picks += ["Package.swift", "proto/agentic/gateway/v1/common.proto"]
    if ext == ".proto" and not path.endswith("common.proto"):
        picks.append("proto/agentic/gateway/v1/common.proto")
    if ext == ".sql":
        picks.append("db/migrations/001_initial.sql")
    folder = os.path.dirname(path)
    siblings = sorted(r["path"] for r in rows
                      if r["type"] == "file" and os.path.dirname(r["path"]) == folder
                      and r["path"] != path and os.path.splitext(r["path"])[1] == ext)
    picks += siblings
    out, total = [], 0
    for p in dict.fromkeys(picks):  # dedupe, keep order
        full = os.path.join(root, p)
        if p == path or not os.path.isfile(full):
            continue
        size = os.path.getsize(full)
        if size == 0 or total + size > MAX_CONTEXT_BYTES or len(out) >= MAX_CONTEXT_FILES:
            continue
        out.append(full)
        total += size
    return out


def prompt_for(row, rows):
    folder = os.path.dirname(row["path"])
    parent = next((r for r in rows if r["type"] == "dir" and r["path"] == folder), None)
    lines = [
        "You are writing ONE file of the agentic-gateway monorepo: a Swift package with a governance "
        "plane (gateway server), an execution plane (Mac ExecutionNode) and a management plane (CRUD APIs).",
        f"File: {row['path']}",
        f"Purpose: {row['purpose']}",
        f"Requirement (must hold): {row['requirement']}",
        f"Layer: {row['layer']}; plane: {row['plane']}; platform: {row['platform']}; status: {row['status']}.",
    ]
    if parent:
        lines += [f"Folder {parent['path']}/: {parent['purpose']} {parent['requirement']}"]
    lines += [
        "",
        "Rules:",
        "- Write a complete, working file. No placeholder bodies, no TODO stubs, no '...'.",
        "- Stay consistent with the read-only reference files below: reuse their type, message and field "
        "names instead of inventing new ones for the same thing.",
        "- Write the first section with write_file, then add each further section with append_file. "
        "Finish by reading the file once to check it.",
    ]
    ext = os.path.splitext(row["path"])[1]
    if ext == ".swift":
        lines += [
            "- Swift 6 with strict concurrency (Sendable types, actors for shared mutable state). "
            "Use Foundation and only packages declared in the reference Package.swift.",
            "- Name helper types after this file's subject so they don't collide with other files.",
        ]
        if row["platform"] == "mac" or row["status"] == "macos-only":
            lines.append("- macOS-only: wrap the file's contents in #if os(macOS) ... #endif.")
    if ext == ".proto":
        lines.append("- proto3, package agentic.gateway.v1 (or a subpackage matching the folder), "
                     "with go_package/swift_prefix options matching the reference.")
    if any(js in row["requirement"] for js in JS_ISMS):
        lines.append("- The requirement names a JavaScript language feature that Swift does not have. "
                     "Implement its intent with Swift equivalents (for example Duration/ContinuousClock for "
                     "timestamps, UInt64 for 64-bit hashes, chunked loops for batching) and add a one-line "
                     "comment saying which JavaScript feature the requirement referred to.")
    return "\n".join(lines)


def run_one(row, rows, args):
    target = os.path.join(args.root, row["path"])
    log_path = os.path.join(args.logs, row["path"].replace("/", "__") + ".log")
    os.makedirs(os.path.dirname(target), exist_ok=True)  # the dispatcher, not the bot, creates folders
    cmd = [sys.executable, os.path.join(HERE, "onefile_bot.py"), "--file", target,
           "--model", args.model, "--max-steps", str(args.max_steps)]
    for c in context_for(row, rows, args.root):
        cmd += ["--context", c]
    cmd.append(prompt_for(row, rows))
    start = time.time()
    with open(log_path, "w", encoding="utf-8") as log:
        log.write("$ " + " ".join(cmd[:-1]) + " <prompt>\n\n" + cmd[-1] + "\n\n--- run ---\n")
        log.flush()
        code = subprocess.call(cmd, stdout=log, stderr=subprocess.STDOUT)
    size = os.path.getsize(target) if os.path.exists(target) else 0
    return {"path": row["path"], "exit": code, "bytes": size, "seconds": round(time.time() - start),
            "log": log_path}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--wave", default="all", help="wave number or 'all'")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--model", default="qwen/qwen3.8-27b")
    ap.add_argument("--max-steps", type=int, default=30)
    ap.add_argument("--logs", default=None)
    ap.add_argument("--overwrite", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    args.root = os.path.abspath(args.root)
    args.logs = os.path.abspath(args.logs or os.path.join(args.root, ".onefile-logs"))
    os.makedirs(args.logs, exist_ok=True)

    rows = load(args.tree)
    files = [r for r in rows if r["type"] == "file"]
    waves = [n for n, _, _ in WAVES] if args.wave == "all" else [int(args.wave)]
    summary = []
    for n in waves:
        todo = [r for r in files if wave_of(r["path"]) == n
                and (args.overwrite or not os.path.exists(os.path.join(args.root, r["path"])))]
        name = next(w for k, w, _ in WAVES if k == n)
        print(f"== wave {n} ({name}): {len(todo)} files", flush=True)
        if args.dry_run:
            for r in todo:
                print(f"   {r['path']}  context={[os.path.relpath(c, args.root) for c in context_for(r, rows, args.root)]}")
            continue
        with cf.ThreadPoolExecutor(args.jobs) as ex:
            for res in ex.map(lambda r: run_one(r, rows, args), todo):
                ok = res["exit"] == 0 and res["bytes"] > 0
                print(f"   {'ok  ' if ok else 'FAIL'} {res['path']} ({res['bytes']} bytes, {res['seconds']}s)",
                      flush=True)
                summary.append(res)
    if summary:
        out = os.path.join(args.logs, "summary.csv")
        new = not os.path.exists(out)
        with open(out, "a", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=list(summary[0].keys()))
            if new:
                w.writeheader()
            w.writerows(summary)
        failed = [s for s in summary if s["exit"] != 0 or s["bytes"] == 0]
        print(f"done: {len(summary) - len(failed)} written, {len(failed)} failed; logs in {args.logs}")
        sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
