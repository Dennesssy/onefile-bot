// OneFileBot.swift — Groq tool-calling loop whose ONLY tools are read/write/edit on one assigned file.
//
// The request's `tools` array is built from the three OneFile tools and nothing else, so the
// model has no way to reach any other file.
//
// Usage: onefile-bot --file /abs/path "what to write" [--model openai/gpt-oss-120b] [--max-steps 12]
// Needs GROQ_API_KEY in the environment.
//
// Build: swiftc -O OneFileBot.swift -o onefile-bot

import Foundation

// MARK: - Errors

enum OneFileError: LocalizedError {
    case directory(String)
    case missingParent(String)
    case tooLarge(String)
    case missingContent
    case missingOldString
    case missingNewString
    case fileDoesNotExist
    case oldStringCount(Int)

    var errorDescription: String? {
        switch self {
        case .directory(let p): return "\(p) is a directory"
        case .missingParent(let p): return "parent directory of \(p) does not exist"
        case .tooLarge(let what): return "\(what) is larger than 1 MB"
        case .missingContent: return "missing content"
        case .missingOldString: return "missing old_string"
        case .missingNewString: return "missing new_string"
        case .fileDoesNotExist: return "file does not exist yet; use write_file first"
        case .oldStringCount(let n): return "old_string must occur exactly once (found \(n) times)"
        }
    }
}

// MARK: - OneFile

final class OneFile {
    let path: String
    private let url: URL

    init(path rawPath: String) throws {
        let resolved = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath()
        self.url = resolved
        self.path = resolved.path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: self.path, isDirectory: &isDir), isDir.boolValue {
            throw OneFileError.directory(self.path)
        }
        let parent = (resolved as NSURL).deletingLastPathComponent?.path ?? ""
        var parentIsDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: parent, isDirectory: &parentIsDir) || !parentIsDir.boolValue {
            throw OneFileError.missingParent(self.path)
        }
    }

    func read() throws -> String {
        if !FileManager.default.fileExists(atPath: path) {
            return "(file \(path) does not exist yet; use write_file to create it)"
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        if let size = attrs[.size] as? Int, size > 1_000_000 {
            throw OneFileError.tooLarge("file")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func write(_ content: String) throws -> String {
        if content.utf8.count > 1_000_000 {
            throw OneFileError.tooLarge("content")
        }
        let data = Data(content.utf8)
        try data.write(to: url, options: .atomic)
        return "wrote \(content.count) characters to \(path)"
    }

    func edit(old: String, new: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw OneFileError.fileDoesNotExist
        }
        let text = try read()
        let count = text.components(separatedBy: old).count - 1
        if old.isEmpty || count != 1 {
            throw OneFileError.oldStringCount(count)
        }
        let result = try write(text.replacingOccurrences(of: old, with: new, options: [], range: nil))
        return result.replacingOccurrences(of: "wrote", with: "edited; now", options: [], range: nil)
    }
}

// MARK: - Tools

func onefileTools(path: String) -> [[String: Any]] {
    return [
        ["type": "function", "function": [
            "name": "read_file",
            "description": "Read the assigned file (\(path)). Takes no arguments.",
            "parameters": ["type": "object", "properties": [String: Any](), "additionalProperties": false] as [String: Any]
        ] as [String: Any]] as [String: Any],
        ["type": "function", "function": [
            "name": "write_file",
            "description": "Create or completely replace the assigned file (\(path)).",
            "parameters": ["type": "object", "properties": ["content": ["type": "string"]],
                           "required": ["content"], "additionalProperties": false] as [String: Any]
        ] as [String: Any]] as [String: Any],
        ["type": "function", "function": [
            "name": "edit_file",
            "description": "Replace one exact, unique occurrence of old_string with new_string in the assigned file (\(path)).",
            "parameters": ["type": "object",
                           "properties": ["old_string": ["type": "string"], "new_string": ["type": "string"]],
                           "required": ["old_string", "new_string"], "additionalProperties": false] as [String: Any]
        ] as [String: Any]] as [String: Any],
    ]
}

// MARK: - HTTP

func stderrPrint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func chat(model: String, apiKey: String, messages: inout [[String: Any]], tools: [[String: Any]]) async -> [String: Any] {
    let groqURL = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    let malformedRetries = 3
    for attempt in 0...(malformedRetries) {
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.2,
            "tools": tools,
            "tool_choice": "auto",
        ]
        let jsonData = try! JSONSerialization.data(withJSONObject: body, options: [])
        var request = URLRequest(url: groqURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("onefile-bot/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = jsonData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as! HTTPURLResponse
            if http.statusCode == 200 {
                let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let choices = json["choices"] as! [[String: Any]]
                return choices[0]["message"] as! [String: Any]
            }
            let detail = String(data: data, encoding: .utf8) ?? ""
            if (response as? HTTPURLResponse)?.statusCode == 400 && detail.contains("tool_use_failed") && attempt < malformedRetries {
                stderrPrint("[retry \(attempt + 1)] model produced an invalid tool call; asking for smaller pieces")
                messages.append(["role": "user", "content":
                    "Your last tool call could not be parsed as JSON and was not executed. Retry with smaller "
                    + "pieces: write_file a short skeleton first, then add one section at a time with edit_file. "
                    + "Keep every JSON string properly escaped."])
                continue
            }
            stderrPrint("Groq HTTP \(http.statusCode): \(String(detail.prefix(500)))")
            exit(1)
        } catch {
            stderrPrint("request failed: \(error.localizedDescription)")
            exit(1)
        }
    }
    fatalError("unreachable")
}

// MARK: - Tool dispatch

func callTool(_ f: OneFile, name: String, args: [String: Any]) -> String {
    do {
        switch name {
        case "read_file":
            return try f.read()
        case "write_file":
            guard let content = args["content"] as? String else {
                throw OneFileError.missingContent
            }
            return try f.write(content)
        case "edit_file":
            guard let old = args["old_string"] as? String else {
                throw OneFileError.missingOldString
            }
            guard let new = args["new_string"] as? String else {
                throw OneFileError.missingNewString
            }
            return try f.edit(old: old, new: new)
        default:
            return "error: unknown tool \(name); only read_file, write_file, edit_file exist"
        }
    } catch {
        return "error: \(error.localizedDescription)"
    }
}

// MARK: - Argument parsing

struct ParsedArgs {
    let file: String
    let context: [String]
    let model: String
    let maxSteps: Int
    let prompt: String
}

func parseArguments() -> ParsedArgs {
    let args = CommandLine.arguments
    var file: String? = nil
    var context: [String] = []
    var model = "openai/gpt-oss-120b"
    var maxSteps = 12
    var prompt: String? = nil
    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--file":
            i += 1
            guard i < args.count else {
                stderrPrint("usage: onefile-bot --file PATH PROMPT [--context PATH]... [--model MODEL] [--max-steps N]")
                exit(2)
            }
            file = args[i]
        case "--context":
            i += 1
            guard i < args.count else {
                stderrPrint("usage: onefile-bot --file PATH PROMPT [--context PATH]... [--model MODEL] [--max-steps N]")
                exit(2)
            }
            context.append(args[i])
        case "--model":
            i += 1
            guard i < args.count else {
                stderrPrint("usage: onefile-bot --file PATH PROMPT [--context PATH]... [--model MODEL] [--max-steps N]")
                exit(2)
            }
            model = args[i]
        case "--max-steps":
            i += 1
            guard i < args.count, let n = Int(args[i]) else {
                stderrPrint("usage: onefile-bot --file PATH PROMPT [--context PATH]... [--model MODEL] [--max-steps N]")
                exit(2)
            }
            maxSteps = n
        default:
            if arg.hasPrefix("--") {
                stderrPrint("unknown option: \(arg)")
                stderrPrint("usage: onefile-bot --file PATH PROMPT [--context PATH]... [--model MODEL] [--max-steps N]")
                exit(2)
            }
            guard prompt == nil else {
                stderrPrint("unexpected extra argument: \(arg)")
                stderrPrint("usage: onefile-bot --file PATH PROMPT [--context PATH]... [--model MODEL] [--max-steps N]")
                exit(2)
            }
            prompt = arg
        }
        i += 1
    }
    guard let file, let prompt else {
        stderrPrint("usage: onefile-bot --file PATH PROMPT [--context PATH]... [--model MODEL] [--max-steps N]")
        exit(2)
    }
    return ParsedArgs(file: file, context: context, model: model, maxSteps: maxSteps, prompt: prompt)
}

// MARK: - Main

@main
struct OneFileBot {
    static func main() async {
        let a = parseArguments()

        guard let apiKey = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !apiKey.isEmpty else {
            stderrPrint("GROQ_API_KEY not set")
            exit(1)
        }

        let f: OneFile
        do {
            f = try OneFile(path: a.file)
        } catch {
            stderrPrint(error.localizedDescription)
            exit(1)
        }

        let tools = onefileTools(path: f.path)

        var reference = ""
        for p in a.context {
            let text = (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
            reference += "\n\n--- reference (read-only): \(p) ---\n\(text)"
        }

        var messages: [[String: Any]] = [
            ["role": "system", "content":
                "You write and edit exactly one file: \(f.path)\n"
                + "Your only tools are read_file, write_file and edit_file; they always act on that file. "
                + "Read the file first, make the requested change, then read it back to check it. "
                + "Finish with a short summary of what you wrote. Do not ask questions."],
            ["role": "user", "content": a.prompt + reference],
        ]

        for step in 0..<a.maxSteps {
            let msg = await chat(model: a.model, apiKey: apiKey, messages: &messages, tools: tools)
            var filtered: [String: Any] = [:]
            for key in ["role", "content", "tool_calls"] {
                if let value = msg[key] {
                    filtered[key] = value
                }
            }
            messages.append(filtered)

            let calls = (msg["tool_calls"] as? [[String: Any]]) ?? []
            if calls.isEmpty {
                let content = (msg["content"] as? String) ?? ""
                print(content)
                exit(0)
            }

            for c in calls {
                let function = c["function"] as? [String: Any] ?? [:]
                let name = (function["name"] as? String) ?? ""
                var args: [String: Any] = [:]
                if let rawArgs = function["arguments"] as? String,
                   let data = rawArgs.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data),
                   let dict = parsed as? [String: Any] {
                    args = dict
                }
                let result = callTool(f, name: name, args: args)
                let firstLine = result.isEmpty ? "" : String(result.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
                stderrPrint("[step \(step + 1)] \(name) -> \(String(firstLine.prefix(100)))")
                messages.append(["role": "tool", "tool_call_id": c["id"] as? String ?? "", "content": result])
            }
        }
        stderrPrint("stopped after \(a.maxSteps) steps without a final answer")
        exit(1)
    }
}