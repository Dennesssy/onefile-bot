// OneFileBot.swift — Groq tool-calling loop whose ONLY tools act on an explicit set of assigned files.
//
// Every tool takes a `file` argument whose JSON schema is an enum of the assigned file names, and the
// name is checked again here before any read or write. There is no shell, no path argument, and no
// other tool in the request, so the model cannot reach any file outside the set.
//
// Usage:
//   onefile-bot --file PATH [--file PATH ...] [--context PATH ...] [--model MODEL] [--max-steps N] "PROMPT"
// Needs GROQ_API_KEY in the environment.
//
// Build: swiftc -O -parse-as-library OneFileBot.swift -o onefile-bot

import Foundation

// MARK: - Errors

enum OneFileError: LocalizedError {
    case directory(String)
    case missingParent(String)
    case tooLarge(String)
    case missingArgument(String)
    case fileDoesNotExist(String)
    case oldStringCount(Int)
    case notAssigned(String, [String])
    case wouldShrink(String, Int, Int)
    case placeholder

    var errorDescription: String? {
        switch self {
        case .directory(let p): return "\(p) is a directory"
        case .missingParent(let p): return "parent directory of \(p) does not exist"
        case .tooLarge(let what): return "\(what) is larger than 1 MB"
        case .missingArgument(let a): return "missing \(a)"
        case .fileDoesNotExist(let p): return "\(p) does not exist yet; use write_file first"
        case .oldStringCount(let n): return "old_string must occur exactly once (found \(n) times)"
        case .placeholder:
            return "refused: that content is a progress note, not file content. Write the actual code for this file."
        case .wouldShrink(let p, let old, let new):
            return "refused: write_file would replace \(p) (\(old) lines) with \(new) lines. The file already "
                + "contains your earlier work; use append_file to add to it or edit_file to change part of it."
        case .notAssigned(let name, let allowed):
            return "\(name) is not one of your assigned files: \(allowed.joined(separator: ", "))"
        }
    }
}

// MARK: - One assigned file

final class OneFile {
    static let maxBytes = 1_000_000
    let path: String
    private let url: URL

    init(path rawPath: String) throws {
        let resolved = URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath()
        url = resolved
        path = resolved.path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            throw OneFileError.directory(path)
        }
        var parentIsDir: ObjCBool = false
        let parent = resolved.deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &parentIsDir), parentIsDir.boolValue else {
            throw OneFileError.missingParent(path)
        }
    }

    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    func read() throws -> String {
        guard exists else { return "(file \(path) does not exist yet; use write_file to create it)" }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        if let size = attrs[.size] as? Int, size > Self.maxBytes { throw OneFileError.tooLarge("file") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func write(_ content: String) throws -> String {
        if content.utf8.count > Self.maxBytes { throw OneFileError.tooLarge("content") }
        if content.contains("[done earlier") || content.contains("characters were written to")
            || content.contains("omitted; read_file") {
            throw OneFileError.placeholder
        }
        if exists, let current = try? String(contentsOf: url, encoding: .utf8), current == content {
            return "unchanged: \(path) already has exactly this content"
        }
        try guardAgainstClobber(content)
        try Data(content.utf8).write(to: url, options: .atomic)  // never leaves a half-written file
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(6).joined(separator: "\n")
        return "wrote \(content.count) characters to \(path); the file now has \(lines.count) lines and ends with:\n\(tail)"
    }

    /// Refuses a write_file that would shrink an existing, substantial file to less than half its size —
    /// the usual sign of a model "restarting" a file it lost track of. Appends and edits are unaffected.
    private var allowShrink = false
    private func guardAgainstClobber(_ content: String) throws {
        guard !allowShrink, exists, let old = try? String(contentsOf: url, encoding: .utf8) else { return }
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).count
        let newLines = content.split(separator: "\n", omittingEmptySubsequences: false).count
        if oldLines >= 40 && newLines * 2 < oldLines {
            throw OneFileError.wouldShrink(path, oldLines, newLines)
        }
    }

    func append(_ content: String) throws -> String {
        let existing = exists ? try read() : ""
        allowShrink = true; defer { allowShrink = false }
        return try write(existing + content).replacingOccurrences(of: "wrote", with: "appended; now")
    }

    func edit(old: String, new: String) throws -> String {
        guard exists else { throw OneFileError.fileDoesNotExist(path) }
        let text = try read()
        let count = old.isEmpty ? 0 : text.components(separatedBy: old).count - 1
        guard count == 1, let range = text.range(of: old) else { throw OneFileError.oldStringCount(count) }
        allowShrink = true; defer { allowShrink = false }
        return try write(text.replacingCharacters(in: range, with: new))
            .replacingOccurrences(of: "wrote", with: "edited; now")
    }
}

// MARK: - The assigned set

final class FileSet {
    /// Short names the model uses, in assignment order (file name, or a longer suffix if names collide).
    let names: [String]
    private let files: [String: OneFile]

    init(paths: [String]) throws {
        let resolved = try paths.map { try OneFile(path: $0) }
        var names: [String] = []
        var files: [String: OneFile] = [:]
        for f in resolved {
            var parts = URL(fileURLWithPath: f.path).pathComponents
            var name = parts.removeLast()
            while files[name] != nil, let parent = parts.popLast() { name = parent + "/" + name }
            names.append(name)
            files[name] = f
        }
        self.names = names
        self.files = files
    }

    /// The model must name an assigned file; with a single file the argument may be omitted.
    func file(_ args: [String: Any]) throws -> OneFile {
        if let name = args["file"] as? String {
            guard let f = files[name] else { throw OneFileError.notAssigned(name, names) }
            return f
        }
        if names.count == 1, let only = files[names[0]] { return only }
        throw OneFileError.missingArgument("file (one of: \(names.joined(separator: ", ")))")
    }

    func path(of name: String) -> String { files[name]?.path ?? name }

    /// Current state of every assigned file: (name, line count or nil when missing/empty).
    func progress() -> [(name: String, lines: Int?)] {
        names.map { name in
            guard let f = files[name], f.exists, let text = try? String(contentsOfFile: f.path, encoding: .utf8),
                  !text.isEmpty else { return (name, nil) }
            return (name, text.split(separator: "\n", omittingEmptySubsequences: false).count)
        }
    }
    var missing: [String] { progress().filter { $0.lines == nil }.map(\.name) }
}

// MARK: - Check

/// Runs the --check command; returns nil when it passes, otherwise the first error lines.
func runCheck(_ command: String?) -> String? {
    guard let command else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", command]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return "could not run check: \(error)" }
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    p.waitUntilExit()
    let errorLines = text.split(separator: "\n").filter { $0.contains("error") || $0.contains("Error") }
    if p.terminationStatus == 0 && errorLines.isEmpty { return nil }
    let shown = errorLines.isEmpty ? text.split(separator: "\n").map(String.init) : errorLines.map(String.init)
    return shown.prefix(15).joined(separator: "\n")
}

/// Numbered source lines around each `path:line:col: error` in the check output (up to 6 errors).
func errorExcerpts(_ failure: String) -> String {
    var out: [String] = []
    let pattern = try! NSRegularExpression(pattern: "^(/[^:]+):(\\d+):\\d+: error", options: .anchorsMatchLines)
    let ns = failure as NSString
    var seen = Set<String>()
    for m in pattern.matches(in: failure, range: NSRange(location: 0, length: ns.length)).prefix(6) {
        let path = ns.substring(with: m.range(at: 1))
        guard let line = Int(ns.substring(with: m.range(at: 2))), seen.insert("\(path):\(line)").inserted,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        let lines = text.components(separatedBy: "\n")
        let lo = max(1, line - 6), hi = min(lines.count, line + 4)
        guard lo <= hi else { continue }
        let block = (lo...hi).map { n in String(format: "%5d%@ %@", n, n == line ? ">" : " ", lines[n - 1]) }
        out.append("\((path as NSString).lastPathComponent) around line \(line):\n" + block.joined(separator: "\n"))
    }
    return out.joined(separator: "\n\n")
}

// MARK: - Dynamic instructions

/// Resolved again before every request (like Foundation Models' DynamicInstructions): the system message
/// always shows the current state of each assigned file and the next action, and the tool choice is
/// "required" while any assigned file is still missing, so the model cannot stop with a plan.
func resolveInstructions(_ set: FileSet, checkFailure: String? = nil) -> (system: String, toolChoice: String) {
    let state = set.progress()
    let lines = state.map { "- \($0.name): " + ($0.lines.map { "written (\($0) lines)" } ?? "MISSING") }
    var text = "You write and edit only these assigned files:\n"
        + set.names.map { "- \($0)  (\(set.path(of: $0)))" }.joined(separator: "\n")
        + "\n\nYour only tools are read_file, write_file, append_file and edit_file, and each takes a `file` "
        + "argument naming one of the assigned files. To create a long file, write_file the first section, then "
        + "append_file each further section in order. Earlier tool exchanges may have been removed to save space: "
        + "use read_file to see a file's current content. Do not ask questions.\n\nCurrent state:\n" + lines.joined(separator: "\n")
    let missing = state.filter { $0.lines == nil }.map(\.name)
    if let next = missing.first {
        text += "\n\nNext: write \(next) now with write_file (then append_file for the rest of it). "
            + "\(missing.count) file(s) still missing. Do not reply with a plan or summary until every file is written."
        return (text, "required")
    }
    if let checkFailure {
        let excerpts = errorExcerpts(checkFailure)
        text += "\n\nThe check still fails with:\n\(checkFailure)"
            + (excerpts.isEmpty ? "" : "\n\nThe code at those lines (> marks the error line):\n\(excerpts)")
            + "\n\nNext: fix them "
            + "with edit_file (or write_file to rewrite a broken file). You are not done until the check passes."
        return (text, "required")
    }
    text += "\n\nAll assigned files exist" + (set.names.isEmpty ? "" : " and pass their check") + ". Check each one once "
        + "(read_file), fix problems with edit_file or append_file, then finish with a short summary of what you wrote."
    return (text, "auto")
}

// MARK: - Tools

func toolDefinitions(_ set: FileSet) -> [[String: Any]] {
    let fileParam: [String: Any] = ["type": "string", "enum": set.names,
                                    "description": "Which assigned file to act on."]
    func tool(_ name: String, _ description: String, _ extra: [String: Any], _ required: [String]) -> [String: Any] {
        var properties = extra
        properties["file"] = fileParam
        return ["type": "function", "function": [
            "name": name,
            "description": description,
            "parameters": ["type": "object", "properties": properties,
                           "required": ["file"] + required, "additionalProperties": false] as [String: Any],
        ] as [String: Any]]
    }
    let text: [String: Any] = ["type": "string"]
    return [
        tool("read_file", "Read one of your assigned files.", [:], []),
        tool("write_file", "Create or completely replace one of your assigned files.", ["content": text], ["content"]),
        tool("append_file", "Append text to the end of one of your assigned files, creating it if needed. "
             + "Use this to build a long file in chunks.", ["content": text], ["content"]),
        tool("edit_file", "Replace one exact, unique occurrence of old_string with new_string in one of your assigned files.",
             ["old_string": text, "new_string": text], ["old_string", "new_string"]),
    ]
}

func callTool(_ set: FileSet, name: String, args: [String: Any]) -> String {
    do {
        let f = try set.file(args)
        func string(_ key: String) throws -> String {
            guard let s = args[key] as? String else { throw OneFileError.missingArgument(key) }
            return s
        }
        switch name {
        case "read_file": return try f.read()
        case "write_file": return try f.write(try string("content"))
        case "append_file": return try f.append(try string("content"))
        case "edit_file": return try f.edit(old: try string("old_string"), new: try string("new_string"))
        default: return "error: unknown tool \(name); only read_file, write_file, append_file, edit_file exist"
        }
    } catch {
        return "error: \(error.localizedDescription)"
    }
}

// MARK: - Groq

func stderrPrint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

/// POSTs JSON with /usr/bin/curl. curl already has network access on this Mac, whereas a freshly
/// rebuilt binary using URLSession can be held by an app firewall (Little Snitch) until approved.
/// The key is read by curl from the GROQ_API_KEY environment variable (--variable/--expand-header),
/// so it never appears in the process arguments.
func curlPost(_ url: String, body: Data) -> (status: Int, data: Data, retryAfter: Double?) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = ["-sS", "--max-time", "300", "-X", "POST", url,
                         "--variable", "%GROQ_API_KEY",
                         "--expand-header", "Authorization: Bearer {{GROQ_API_KEY}}",
                         "-H", "Content-Type: application/json", "-H", "User-Agent: onefile-bot/1.0",
                         "--data-binary", "@-",
                         "-w", "\n%{http_code} %header{retry-after}"]
    let input = Pipe(), output = Pipe(), errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    do { try process.run() } catch { return (0, Data("curl failed to start: \(error)".utf8), nil) }
    DispatchQueue.global().async {  // feed the body while curl runs, so large bodies can't deadlock the pipes
        input.fileHandleForWriting.write(body)
        try? input.fileHandleForWriting.close()
    }
    var data = output.fileHandleForReading.readDataToEndOfFile()
    let stderrText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard let cut = data.lastIndex(of: UInt8(ascii: "\n")) else { return (0, Data(stderrText.utf8), nil) }
    let trailer = String(decoding: data[data.index(after: cut)...], as: UTF8.self).split(separator: " ")
    data = data[..<cut]
    let status = trailer.first.flatMap { Int($0) } ?? 0
    return (status, status == 0 ? Data(stderrText.utf8) : data, trailer.count > 1 ? Double(trailer[1]) : nil)
}

func chat(model: String, apiKey: String, messages: inout [[String: Any]], tools: [[String: Any]], toolChoice: String = "auto") async -> (message: [String: Any], usage: [String: Any]) {
    let retries = 10
    for attempt in 0...retries {
        // max_tokens must be explicit: without it Groq caps qwen3.8-27b tool-call content at ~1,000
        // characters and still reports finish_reason "tool_calls", silently truncating files.
        let body: [String: Any] = ["model": model, "messages": messages, "temperature": 0.2,
                                   "tools": tools, "tool_choice": toolChoice, "max_tokens": 16_000]
        guard let json = try? JSONSerialization.data(withJSONObject: body) else {
            stderrPrint("could not encode request"); exit(1)
        }
        let (status, data, retryAfter) = curlPost("https://api.groq.com/openai/v1/chat/completions", body: json)
        if status == 200,
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = decoded["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any] {
            return (message, decoded["usage"] as? [String: Any] ?? [:])
        }
        let detail = String(decoding: data, as: UTF8.self)
        if attempt < retries && (status == 429 || status == 503 || status == 0) {
            // Groq's retry-after is often ~2 s for TPM limits, but parallel bots refill the window at once;
            // wait at least an escalating floor so retries don't all fail together.
            let wait = min(max(retryAfter ?? 0, Double(10 * (attempt + 1))), 90)
            stderrPrint("[retry \(attempt + 1)] \(status == 0 ? "network error: " + detail.prefix(120) : "Groq HTTP \(status)"); waiting \(Int(wait))s")
            try? await Task.sleep(for: .seconds(wait))
            continue
        }
        if status == 400, detail.contains("tool_use_failed"), attempt < retries {
            stderrPrint("[retry \(attempt + 1)] model produced an invalid tool call; asking for smaller pieces")
            messages.append(["role": "user", "content":
                "Your last tool call could not be parsed as JSON and was not executed. Retry with smaller "
                + "pieces: write_file a short skeleton first, then add one section at a time with append_file. "
                + "Keep every JSON string properly escaped."])
            continue
        }
        stderrPrint("Groq HTTP \(status): \(detail.prefix(500))")
        exit(1)
    }
    exit(1)
}

// MARK: - Context management

/// Keeps every request small: file text the model already wrote is replaced by a short note in the
/// assistant's tool-call arguments, and older read_file results for a file are dropped once the file is
/// read again or changed. The model can always read_file to see current content.
struct History {
    static let compactAbove = 12_000  // input tokens per request
    private var readIndex: [String: Int] = [:]   // file name -> index of the latest read_file result message


    /// Call after appending a tool result message at `index` for tool `name` on `file`.
    /// Only a newer read of the same file makes an older read redundant.
    mutating func record(_ name: String, file: String, index: Int, messages: inout [[String: Any]]) {
        guard name == "read_file" else { return }
        if let previous = readIndex[file], previous < messages.count {
            messages[previous]["content"] = "[older read of \(file) omitted; a newer read follows]"
        }
        readIndex[file] = index
    }

    /// Removes every tool exchange before the latest assistant turn: the assistant messages with their
    /// tool calls, the matching tool results, and nudges. Nothing is replaced with placeholder text (a
    /// model copies placeholders into files); the per-request instructions already show each file's state.
    static func compactEarlierTurns(_ messages: inout [[String: Any]]) {
        guard let latest = messages.lastIndex(where: { $0["role"] as? String == "assistant" }), latest > 2 else { return }
        messages.removeSubrange(2..<latest)  // keep [system, task], then the latest turn onward
    }
}

// MARK: - Arguments

struct Options {
    var files: [String] = []
    var context: [String] = []
    var model = "qwen/qwen3.8-27b"
    var maxSteps = 30
    var check: String?   // shell command that must succeed (exit 0, no "error:") before the job counts as done
    var prompt: String?
}

func usage() -> Never {
    stderrPrint("usage: onefile-bot --file PATH [--file PATH ...] [--context PATH ...] [--check CMD] [--model MODEL] [--max-steps N] PROMPT")
    exit(2)
}

func parseArguments() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst()
    func value() -> String {
        guard let v = args.popFirst() else { usage() }
        return v
    }
    while let arg = args.popFirst() {
        switch arg {
        case "--file": o.files.append(value())
        case "--context": o.context.append(value())
        case "--model": o.model = value()
        case "--check": o.check = value()
        case "--max-steps":
            guard let n = Int(value()), n > 0 else { usage() }
            o.maxSteps = n
        default:
            if arg.hasPrefix("--") || o.prompt != nil { stderrPrint("unexpected argument: \(arg)"); usage() }
            o.prompt = arg
        }
    }
    if o.files.isEmpty || o.prompt == nil { usage() }
    return o
}

// MARK: - Main

@main
struct OneFileBot {
    static func main() async {
        let o = parseArguments()
        guard let apiKey = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !apiKey.isEmpty else {
            stderrPrint("GROQ_API_KEY not set")
            exit(1)
        }
        let set: FileSet
        do { set = try FileSet(paths: o.files) } catch { stderrPrint(error.localizedDescription); exit(1) }

        let tools = toolDefinitions(set)
        var reference = ""
        for p in o.context {
            let text = (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
            reference += "\n\n--- reference (read-only): \(p) ---\n\(text)"
        }
        var messages: [[String: Any]] = [
            ["role": "system", "content": resolveInstructions(set).system],
            ["role": "user", "content": o.prompt! + reference],
        ]

        var history = History()
        var nudges = 0
        var idleTurns = 0  // turns where every file exists and nothing changed
        var readsWithoutChange = 0  // consecutive turns that only read files
        for step in 1...o.maxSteps {
            let failure = set.missing.isEmpty ? runCheck(o.check) : nil
            let resolved = resolveInstructions(set, checkFailure: failure)
            messages[0] = ["role": "system", "content": resolved.system]
            // Tools are resolved per request too: after two reads in a row with no change, read_file is
            // withheld so the model has to act on what it has already seen.
            let requestTools = readsWithoutChange >= 2
                ? tools.filter { (($0["function"] as? [String: Any])?["name"] as? String) != "read_file" } : tools
            let (msg, usage) = await chat(model: o.model, apiKey: apiKey, messages: &messages, tools: requestTools,
                                          toolChoice: resolved.toolChoice)
            let inputTokens = usage["prompt_tokens"] as? Int ?? 0
            var stored = msg.filter { ["role", "content", "tool_calls"].contains($0.key) }
            let calls = msg["tool_calls"] as? [[String: Any]] ?? []
            if calls.isEmpty {
                let missing = set.missing
                if missing.isEmpty && runCheck(o.check) == nil {
                    print(msg["content"] as? String ?? "")
                    exit(0)
                }
                // Backstop: a text-only reply while files are missing is not completion.
                nudges += 1
                let reason = missing.isEmpty ? "the check still fails" : "\(missing.count) file(s) missing"
                stderrPrint("[step \(step)] text reply while \(reason); nudge \(nudges)")
                if nudges > 3 { stderrPrint("gave up: \(reason)"); exit(3) }
                messages.append(stored)
                messages.append(["role": "user", "content": missing.isEmpty
                    ? "Not finished: the check still fails. Fix the errors listed in your instructions with edit_file."
                    : "Not finished: \(missing.joined(separator: ", ")) still missing. Write \(missing[0]) now with write_file."])
                continue
            }

            // Compact this turn's tool-call arguments before storing the assistant message.
            var compactedCalls: [[String: Any]] = []
            var parsed: [(id: String, name: String, args: [String: Any], target: String)] = []
            for call in calls {
                let function = call["function"] as? [String: Any] ?? [:]
                let name = function["name"] as? String ?? ""
                let args = (function["arguments"] as? String)
                    .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                let target = args["file"] as? String ?? (set.names.count == 1 ? set.names[0] : "?")
                parsed.append((call["id"] as? String ?? "", name, args, target))
                compactedCalls.append(call)
            }
            if !calls.isEmpty { stored["tool_calls"] = compactedCalls }
            messages.append(stored)
            // Compact only once requests get large: small jobs keep full history (fewer mistakes); large
            // multi-file jobs stay under Groq's tokens-per-minute limit. This turn always stays intact.
            if inputTokens > History.compactAbove {
                History.compactEarlierTurns(&messages)
                history = History()  // indexes into removed messages are no longer valid
            }
            var changed = false
            for c in parsed {
                let result = callTool(set, name: c.name, args: c.args)
                if c.name != "read_file" && !result.hasPrefix("unchanged") && !result.hasPrefix("error") { changed = true }
                let first = result.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
                stderrPrint("[step \(step)] \(c.name) \(c.target) -> \(first.prefix(100))  (request: \(inputTokens) input tokens)")
                messages.append(["role": "tool", "tool_call_id": c.id, "content": result])
                history.record(c.name, file: c.target, index: messages.count - 1, messages: &messages)
            }
            idleTurns = (set.missing.isEmpty && !changed && runCheck(o.check) == nil) ? idleTurns + 1 : 0
            readsWithoutChange = (!changed && parsed.allSatisfy { $0.name == "read_file" }) ? readsWithoutChange + 1 : 0
            if idleTurns >= 2 {
                print("All assigned files written; the model is only re-checking them, so finishing.")
                exit(0)
            }
        }
        if set.missing.isEmpty, runCheck(o.check) == nil {
            print("All assigned files written (stopped at the \(o.maxSteps)-step limit while reviewing).")
            exit(0)
        }
        if let failure = runCheck(o.check), set.missing.isEmpty {
            stderrPrint("stopped after \(o.maxSteps) steps; check still fails:\n\(failure)")
            exit(1)
        }
        stderrPrint("stopped after \(o.maxSteps) steps; still missing: \(set.missing.joined(separator: ", "))")
        exit(1)
    }
}
