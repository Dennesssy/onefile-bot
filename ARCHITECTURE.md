# onefile-bot — architecture

A Groq-backed coding bot that can read, write, and edit exactly one assigned file.

```
 you / orchestrator (shell, script, or another agent)
        │  onefile_bot.py --file PATH "what to write" [--context ref.swift ...]
        ▼
 ┌──────────────────────────────────────┐
 │ onefile_bot.py  (tool-calling loop)  │  model: openai/gpt-oss-120b on Groq (default)
 │  request.tools = [read_file,         │  ◄── SECURITY BOUNDARY 1: the model is offered
 │                   write_file,        │      these three tools and nothing else
 │                   edit_file]         │      (no shell, no web, no other files)
 │  --context files → pasted into the   │  ◄── reference material is read by the loop,
 │  prompt as read-only text            │      never exposed as a tool
 └──────────────┬───────────────────────┘
                │ in-process call
                ▼
 ┌──────────────────────────────────────┐
 │ OneFile(PATH)   (onefile_mcp.py)     │  ◄── SECURITY BOUNDARY 2: path fixed at launch,
 │  read()  write(content)  edit(o, n)  │      symlinks resolved once; tools take no path
 └──────────────┬───────────────────────┘      argument, extra arguments are ignored
                ▼
           the one file   (atomic writes via temp file + rename)
```

The same `OneFile` class is also served over MCP stdio (`onefile_mcp.py --file PATH`) so
MCP clients can use it. Note: a host such as nanobot that injects its own built-in tools
(bash, edit, ...) defeats the confinement; see README "Why not nanobot".

| Constraint | Value |
|---|---|
| Files per bot | 1 (launch argument, never a tool argument) |
| Tools offered to the model | `read_file`, `write_file`, `edit_file` (exact, unique string replace) |
| Max file size | 1 MB for reads and writes |
| Max tool steps | 12 by default (`--max-steps`) |
| Runtime | Python 3.9+ standard library only; Groq OpenAI-compatible API |
| Secrets | `GROQ_API_KEY` from the environment only; never written to disk or logs |
| Parallelism | one process per file; limited by Groq rate limits, not CPU |

```
onefile-bot/
├── ARCHITECTURE.md
├── README.md
├── onefile_bot.py        Groq tool-calling loop (the bot)
├── onefile_mcp.py        OneFile class + MCP stdio server exposing it
└── tests/test_onefile.py confinement and editing tests (no network needed)
```

Roadmap: v1 one bot / one file (this) → v2 Swift port (`swift` branch): single binary,
async URLSession, structured concurrency for parallel bots → v3 validator loop (compile/test,
feed errors back) built in → v4 on-device Core ML text classifier that routes context to files.
