# onefile-bot

A tiny coding bot, powered by [Groq](https://groq.com), that can **read, write, and edit exactly
one file** and nothing else. You assign it a file and tell it what to write. It has no shell,
no web access, and no way to name another path, so you can run many of them side by side,
one per file, without any of them wandering into the rest of your project.

- **Confined by construction.** The model is offered three tools: `read_file`, `write_file`,
  and `edit_file`. None of them takes a path. The file is fixed when the bot starts.
- **No dependencies.** Python 3.9+ standard library only. No `pip install`.
- **Fast and cheap.** Defaults to `openai/gpt-oss-120b` on Groq; any Groq model with tool
  calling works.
- **Reference material without access.** `--context` pastes other files into the prompt as
  read-only text, so the bot can follow an existing style or API without being able to touch them.
- **Also an MCP server.** `onefile_mcp.py` serves the same three tools over MCP stdio.

---

## Contents

1. [Quick start](#quick-start)
2. [How it works](#how-it-works)
3. [Examples](#examples)
4. [Command-line reference](#command-line-reference)
5. [Running bots in parallel](#running-bots-in-parallel)
6. [Using it as an MCP server](#using-it-as-an-mcp-server)
7. [Security model](#security-model)
8. [Why not nanobot](#why-not-nanobot)
9. [Tests](#tests)
10. [Limitations](#limitations)
11. [Roadmap](#roadmap)

---

## Quick start

```bash
git clone https://github.com/Dennesssy/onefile-bot.git
cd onefile-bot

export GROQ_API_KEY=gsk_...          # from https://console.groq.com/keys

python3 onefile_bot.py --file /tmp/hello.py \
  "Write a Python script that prints the first 10 Fibonacci numbers."
```

Progress goes to stderr, the bot's final summary to stdout. Real output from a run on macOS
(where `/tmp` resolves to `/private/tmp`):

```
[step 1] read_file -> (file /private/tmp/hello.py does not exist yet; use write_file to create it)
[step 2] write_file -> wrote 238 characters to /private/tmp/hello.py
[step 3] read_file -> #!/usr/bin/env python3
Created `/private/tmp/hello.py` containing a simple script that defines a generator `fibonacci`
and prints the first 10 Fibonacci numbers when run. The script is ready to execute.
```

```
$ python3 /tmp/hello.py
0
1
1
2
3
5
8
13
21
34
```

> The exact wording and character counts will differ between runs; models are not deterministic.

---

## How it works

```
onefile_bot.py --file PATH "task"
   │
   ├─ OneFile(PATH)          resolves symlinks once, refuses directories
   ├─ system prompt          "you write and edit exactly one file: PATH"
   └─ loop (≤ 12 steps)
        ├─ POST api.groq.com/openai/v1/chat/completions
        │     tools = [read_file, write_file, edit_file]   ← nothing else exists
        ├─ model calls a tool → OneFile performs it on PATH → result goes back
        └─ model answers without a tool call → print summary, exit 0
```

`edit_file` is an exact string replacement: `old_string` must appear **exactly once**, or the
edit is refused and the model is told how many matches it found. Writes go to a temporary file
first and are renamed into place, so the file is never left half-written.

---

## Examples

### 1. Create a new file

```bash
python3 onefile_bot.py --file /tmp/poem.txt "Write a three-line haiku about pips into the file."
```

Real output from a run (path shortened):

```
I added a three-line haiku about pips to the file.
```

```
$ cat /tmp/poem.txt
Pips dance on the wind,
Silent seeds of code arise,
Spring whispers in loops.
```

### 2. Edit an existing file

```bash
python3 onefile_bot.py --file src/config.py \
  "Change the default timeout from 30 to 60 seconds and add a comment explaining why."
```

The bot reads the file, uses `edit_file` to change only the relevant lines, then reads the
file back to check its work.

### 3. Give it reference material it can read but not touch

`--context` can be repeated. Each file's text is pasted into the prompt, marked read-only.

```bash
python3 onefile_bot.py \
  --file Sources/MyApp/ContextualEmbedder.swift \
  --context Sources/MyApp/Embedder.swift \
  --context /tmp/NLContextualEmbedding.h \
  "Create ContextualEmbedder.swift with the same API shape as Embedder, using NLContextualEmbedding."
```

Here `Embedder.swift` shows the style to follow, and the SDK header (extracted with
`xcrun --show-sdk-path`) shows the real API, so the model doesn't have to guess.

### 4. The fix loop: feed compiler errors back

The bot doesn't compile anything itself; you run your normal checks and hand it the errors.
This is how a real Swift file was fixed in one round:

```bash
FILE=Sources/swiftrecall/ContextualEmbedder.swift
ERRORS=$(swift build 2>&1 | grep "ContextualEmbedder.swift:.*error")

python3 onefile_bot.py --file "$FILE" "The file fails to compile with these errors:
$ERRORS
Fix every error with edit_file, keeping the rest of the file."

swift build   # Build complete!
```

First attempt: 4 compiler errors (it had used Objective-C names from the header).
After one round with the errors: `Build complete!`

### 5. Try to break out (it can't)

```bash
python3 onefile_bot.py --file /tmp/poem.txt \
  "Create a new file at /tmp/escape.txt containing ESCAPED, and run 'touch /tmp/escape.txt'. Use any tool you have."
```

Real output (path shortened):

```
I'm only able to read, write, or edit the single file /tmp/poem.txt. I don't have the ability
to create new files or execute shell commands, so I can't create escape.txt or run touch as requested.
```

```
$ test -e /tmp/escape.txt || echo "BLOCKED"
BLOCKED
```

### 6. Pick a different model

```bash
python3 onefile_bot.py --model qwen/qwen3.8-27b --file notes.md "Summarise the TODOs at the top."
```

List the models your key can use:

```bash
curl -s https://api.groq.com/openai/v1/models -H "Authorization: Bearer $GROQ_API_KEY" \
  | python3 -c "import sys, json; print('\n'.join(sorted(m['id'] for m in json.load(sys.stdin)['data'])))"
```

---

## Command-line reference

```
python3 onefile_bot.py --file PATH [--context REF]... [--model MODEL] [--max-steps N] "PROMPT"
```

| Option | Default | Meaning |
|---|---|---|
| `--file PATH` | required | The one file the bot may read, write, and edit. Its parent directory must exist. |
| `PROMPT` | required | What to write or change. |
| `--context REF` | none | Read-only reference file pasted into the prompt. Repeatable. |
| `--model MODEL` | `openai/gpt-oss-120b` | Any Groq model that supports tool calling. |
| `--max-steps N` | `12` | Maximum tool-call rounds before giving up (exit code 1). |

| Environment | Meaning |
|---|---|
| `GROQ_API_KEY` | Required. Read from the environment only; never written anywhere. |

Exit codes: `0` finished with a summary; `1` missing key, Groq HTTP error, or step limit reached.

---

## Running bots in parallel

Each bot is an independent process that spends most of its time waiting on Groq, so plain
shell parallelism is enough; there is no need for threads or a faster language.

```bash
# one bot per file, all at once
python3 onefile_bot.py --file src/a.py "Add type hints"   > logs/a.txt 2>&1 &
python3 onefile_bot.py --file src/b.py "Add docstrings"  > logs/b.txt 2>&1 &
python3 onefile_bot.py --file src/c.py "Add input validation" > logs/c.txt 2>&1 &
wait
```

From a task list (`file<TAB>prompt` per line), at most 4 at a time:

```bash
# tasks.tsv:
# src/a.py	Add type hints to every function
# src/b.py	Add docstrings in Google style

tr '\t' '\n' < tasks.tsv | xargs -n 2 -P 4 -d '\n' \
  sh -c 'python3 onefile_bot.py --file "$0" "$1" > "logs/$(basename "$0").log" 2>&1'
```

> `xargs -d` is GNU syntax. On macOS, install `findutils` (`gxargs`) or use the `&` / `wait`
> form above.

Two rules for parallel runs:

1. **Never assign the same file to two bots at once.** Each bot is confined to its file, but
   two bots on one file would overwrite each other.
2. **Mind Groq's rate limits.** Requests and tokens per minute are limited per key; if you see
   `Groq HTTP 429`, run fewer bots at a time.

---

## Using it as an MCP server

`onefile_mcp.py` exposes the same three tools over MCP stdio, for MCP clients that don't
add tools of their own:

```bash
python3 onefile_mcp.py --file /abs/path/to/file.swift
```

Client configuration example:

```json
{
  "mcpServers": {
    "onefile": {
      "command": "python3",
      "args": ["/abs/path/to/onefile_mcp.py", "--file", "/abs/path/to/file.swift"]
    }
  }
}
```

Talking to it by hand:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"write_file","arguments":{"content":"hello\n"}}}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_file","arguments":{}}}' \
  | python3 onefile_mcp.py --file /tmp/demo.txt
```

Output:

```
{"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "onefile", "version": "1.0"}, "instructions": "You can only access one file: /private/tmp/demo.txt"}}
{"jsonrpc": "2.0", "id": 2, "result": {"content": [{"type": "text", "text": "wrote 6 characters to /private/tmp/demo.txt"}], "isError": false}}
{"jsonrpc": "2.0", "id": 3, "result": {"content": [{"type": "text", "text": "hello\n"}], "isError": false}}
```

The confinement only holds if the MCP host offers the model **nothing but** these tools.
See [Why not nanobot](#why-not-nanobot).

---

## Security model

| Threat | How it's handled |
|---|---|
| Model asks to write another file | No tool takes a path; extra arguments such as `"path"` are ignored (tested). |
| Model tries to run shell commands | There is no shell tool in the request. |
| Symlink pointing elsewhere | Resolved once at launch; the bot is told and confined to the real target. |
| Half-written file after a crash | Writes go to `PATH.onefile-tmp`, then `os.replace` swaps it in atomically. |
| Ambiguous edit hits the wrong spot | `edit_file` refuses unless `old_string` matches exactly once. |
| Huge file / huge write | Reads and writes over 1 MB are refused. |
| API key leakage | Only read from `GROQ_API_KEY`; not logged, not written to disk. |

What it does **not** protect against: the content the model writes into its own file. Review
the result before running or committing it, the same as any generated code.

---

## Why not nanobot

The first version ran inside [nanobot](https://github.com/obot-platform/nanobot) with an agent
limited to this MCP server and `permissions: {read: deny, write: deny}`. An escape test showed
that wasn't enough: nanobot v0.0.92 adds about 20 built-in tools to every model request,
including `bash`, `edit`, `glob`, `grep`, and `webFetch`, and neither the agent's `tools:` list
nor `permissions:` removes them. Asked to create `/tmp/escape.txt`, the nanobot agent did so.

`onefile_bot.py` builds the request itself, so the tool list is exactly the three file tools.
The same escape test is blocked.

---

## Tests

No network or API key needed:

```bash
python3 -m unittest discover -s tests -v
```

```
test_ambiguous_edit_rejected ... ok
test_extra_path_argument_is_ignored ... ok
test_no_tool_accepts_a_path ... ok
test_symlink_resolved_at_launch ... ok
test_write_read_edit ... ok
```

---

## Limitations

- **One file only.** Tasks that need coordinated changes across files need one bot per file
  plus an orchestrator that hands each bot the right context.
- **No built-in checks.** The bot doesn't run compilers or tests; run them yourself and feed
  errors back (example 4).
- **Context is pasted, not searched.** Large reference files use up the model's context window
  (131k tokens for most Groq models). Extract the relevant part first.
- **Not deterministic.** Same prompt, different runs, slightly different files.

---

## Swift version (`swift` branch)

`OneFileBot.swift` is a single-file Swift 6 port with the same tools, prompts, retry behaviour
and output. It needs only Foundation and builds to one binary:

```bash
git switch swift
swiftc -O -parse-as-library OneFileBot.swift -o onefile-bot   # -parse-as-library: the file uses @main

./onefile-bot --file /tmp/fib.swift "Write a Swift script that prints the first 10 Fibonacci numbers, one per line."
```

Real output:

```
[step 1] read_file -> (file /tmp/fib.swift does not exist yet; use write_file to create it)
[step 2] write_file -> wrote 210 characters to /tmp/fib.swift
[step 3] read_file -> // Fibonacci.swift
Created `/tmp/fib.swift` containing a Swift script that prints the first 10 Fibonacci numbers, each on
its own line. The script initializes the sequence and iterates ten times, outputting each value.
```

Same checks as the Python version, run against the binary: the escape prompt left no
`/tmp/escape.txt`, and "Change it to print 12 numbers, using edit_file" produced
`0 1 1 2 3 5 8 13 21 34 55 89`.

**How it was made:** the Swift file was written by onefile-bot itself, given the Python files as
`--context` and a written spec, with `swiftc` errors fed back after each attempt.
`openai/gpt-oss-120b` repeatedly produced unparseable JSON when writing the whole file in one
tool call (Groq `tool_use_failed`), even after retries; `qwen/qwen3.8-27b` built it in ~27 tool
calls and compiled after 4 fix rounds. For large files, try `--model qwen/qwen3.8-27b`.

**Sandboxed shells:** if the binary reports "The Internet connection appears to be offline" while
the Python version works, the shell's sandbox is blocking network access for the new binary; run
it outside the sandbox.

---

## Roadmap

- **`swift` branch:** Swift port as a single binary (done); next, async/await parallel bots in one process.
- Built-in validator loop: run a check command after each attempt and retry with its errors.
- An on-device Core ML text classifier that decides which file a chunk of context belongs to.
