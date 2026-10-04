// FixLoop.swift — repairs ONE Swift file until it compiles by looping:
// compile -> LSP lookup -> SDK lookup -> edit (via onefile-bot).
//
// Usage: fixloop --file PATH [--build CMD] [--bot CMD] [--model MODEL] [--max-rounds N]
//
// Build: swiftc -O -parse-as-library FixLoop.swift -o fixloop

import Foundation

// MARK: - Errors

struct CompileError: Equatable {
    let line: Int
    let col: Int
    let message: String

    var key: String { "\(line):\(col): \(message)" }
}

// MARK: - Shell

func sh(_ command: String) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "failed to run: \(error.localizedDescription)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let s: Int32 = process.terminationStatus
    let out = String(data: data, encoding: .utf8) ?? ""
    return (s, out)
}

// MARK: - Argument parsing

struct Options {
    var file: String = ""
    var build: String = ""
    var bot: String = "./onefile-bot"
    var model: String = "qwen/qwen3.8-27b"
    var maxRounds: Int = 5
}

func usage() -> Never {
    FileHandle.standardError.write(Data(
        "usage: fixloop --file PATH [--build CMD] [--bot CMD] [--model MODEL] [--max-rounds N]\n".utf8))
    exit(2)
}

func parseArgs(_ argv: [String]) -> Options {
    var opts = Options()
    var i = 1
    while i < argv.count {
        let arg = argv[i]
        func nextValue() -> String {
            i += 1
            guard i < argv.count else { usage() }
            return argv[i]
        }
        switch arg {
        case "--file":
            opts.file = nextValue()
        case "--build":
            opts.build = nextValue()
        case "--bot":
            opts.bot = nextValue()
        case "--max-rounds":
            let v = nextValue()
            guard let n = Int(v) else { usage() }
            opts.maxRounds = n
        case "--model":
            opts.model = nextValue()
        default:
            usage()
        }
        i += 1
    }
    guard !opts.file.isEmpty else { usage() }
    opts.file = (opts.file as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: opts.file)
    opts.file = url.standardizedFileURL.path
    let path = URL(fileURLWithPath: opts.file).path
    opts.file = path
    if opts.build.isEmpty {
        opts.build = "xcrun swiftc -parse-as-library '\(path)' -o /tmp/fixloop-build-output"
    }
    return opts
}

// MARK: - Compile step

func stripANSI(_ s: String) -> String {
    guard let re = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m") else { return s }
    let range = NSRange(s.startIndex..., in: s)
    return re.stringByReplacingMatches(in: s, range: range, withTemplate: "")
}

func parseErrors(output: String, targetName: String) -> [CompileError] {
    let clean = stripANSI(output)
    guard let re = try? NSRegularExpression(
        pattern: "^(.+?):(\\d+):(\\d+): error: (.+)$",
        options: [.anchorsMatchLines]) else { return [] }
    let ns = clean as NSString
    let matches = re.matches(in: clean, range: NSRange(location: 0, length: ns.length))
    var seen = Set<String>()
    var result: [CompileError] = []
    for m in matches {
        let filePart = ns.substring(with: m.range(at: 1))
        guard filePart.hasSuffix(targetName) else { continue }
        let line = Int(ns.substring(with: m.range(at: 2))) ?? 0
        let col = Int(ns.substring(with: m.range(at: 3))) ?? 0
        let message = ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
        let err = CompileError(line: line, col: col, message: message)
        if seen.insert(err.key).inserted {
            result.append(err)
        }
    }
    return result
}

// MARK: - LSP client

final class LSPClient {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var buffer = Data()
    private var nextID = 1
    private var running = false

    init() {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["sourcekit-lsp"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
    }

    func start() throws {
        try process.run()
        running = true
    }

    func send(method: String, params: [String: Any], id: Int? = nil) {
        var obj: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { obj["id"] = id }
        if !params.isEmpty { obj["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let header = "Content-Length: \(data.count)\r\n\r\n"
        let handle = stdinPipe.fileHandleForWriting
        handle.write(Data(header.utf8))
        write(handle: handle, data: data)
    }

    private func write(handle: FileHandle, data: Data) {
        var remaining = data
        while !remaining.isEmpty {
            let chunk = remaining.prefix(65536)
            handle.write(chunk)
            remaining = remaining.dropFirst(chunk.count)
        }
    }

    func readMessage() -> [String: Any]? {
        let handle = stdoutPipe.fileHandleForReading
        while true {
            if let msg = tryDecode() { return msg }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }

    private func tryDecode() -> [String: Any]? {
        let text = String(data: buffer, encoding: .utf8) ?? ""
        guard let headerEnd = text.range(of: "\r\n\r\n") else { return nil }
        let header = text[..<headerEnd.lowerBound]
        var length = 0
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "Content-Length" else { continue }
            length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let headerBytes = Data(text[..<headerEnd.upperBound].utf8)
        let bodyStart = headerBytes.count
        guard buffer.count >= bodyStart + length else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        buffer.removeSubrange(..<(bodyStart + length))
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return obj
    }

    func request(method: String, params: [String: Any]) -> Any? {
        let id = nextID
        nextID += 1
        send(method: method, params: params, id: id)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            guard let msg = readMessage() else { break }
            guard let msgID = msg["id"] as? Int, msgID == id else { continue }
            return msg["result"]
        }
        return nil
    }

    func shutdown() {
        send(method: "shutdown", params: [:], id: nextID)
        nextID += 1
        _ = request(method: "exit", params: [:])
        if running {
            process.terminate()
            running = false
        }
    }
}

// MARK: - LSP facts

struct LSPFacts {
    var hover: String = ""
    var completions: String = ""
}

func lspFacts(for errors: [CompileError], filePath: String) -> [String: LSPFacts] {
    var facts: [String: LSPFacts] = [:]
    let url = URL(fileURLWithPath: filePath)
    let client = LSPClient()
    do {
        try client.start()
    } catch {
        for e in errors { facts[e.key] = LSPFacts(hover: "LSP unavailable: \(error.localizedDescription)", completions: "") }
        return facts
    }
    let processID = Int32(getpid())
    let rootUri = url.deletingLastPathComponent().absoluteString
    client.send(method: "initialize", params: [
        "processId": processID,
        "rootUri": rootUri,
        "capabilities": [String: Any](),
    ], id: 1)
    client.send(method: "initialized", params: [:])
    let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    client.send(method: "textDocument/didOpen", params: [
        "textDocument": [
            "uri": url.absoluteString,
            "languageId": "swift",
            "version": 1,
            "text": text,
        ] as [String: Any],
    ])
    Thread.sleep(forTimeInterval: 2)
    for e in errors.prefix(8) {
        let position: [String: Any] = ["line": e.line - 1, "character": e.col - 1]
        let hoverResult = client.request(method: "textDocument/hover", params: [
            "textDocument": ["uri": url.absoluteString] as [String: Any],
            "position": position,
        ])
        var hoverText = ""
        if let result = hoverResult {
            if let dict = result as? [String: Any] {
                if let contents = dict["contents"] {
                    if let value = (contents as? [String: Any])?["value"] as? String {
                        hoverText = value
                    } else if let s = contents as? String {
                        hoverText = s
                    }
                }
            }
        }
        hoverText = String(hoverText.prefix(600))
        let completionResult = client.request(method: "textDocument/completion", params: [
            "textDocument": ["uri": url.absoluteString] as [String: Any],
            "position": position,
        ])
        var labels: [String] = []
        if let result = completionResult {
            var items: [Any]? = nil
            if let dict = result as? [String: Any] {
                items = dict["items"] as? [Any]
            } else if let arr = result as? [Any] {
                items = arr
            }
            if let items {
                for item in items.prefix(30) {
                    if let label = (item as? [String: Any])?["label"] as? String {
                        labels.append(label)
                    }
                }
            }
        }
        facts[e.key] = LSPFacts(hover: hoverText, completions: labels.joined(separator: ", "))
    }
    client.shutdown()
    return facts
}

// MARK: - SDK lookup

let swiftBasics: Set<String> = ["String", "Int", "Double", "Float", "Bool", "Array", "Dictionary", "Data", "URL", "Any"]

func sdkLookup(errorMessages: [String]) -> [(name: String, excerpt: String)] {
    let sdk = sh("xcrun --sdk macosx --show-sdk-path").output.trimmingCharacters(in: .whitespacesAndNewlines)
    var names: [String] = []
    var seen = Set<String>()
    let patterns = ["type '([A-Za-z_][A-Za-z0-9_]*)'", "value of type '([A-Za-z_][A-Za-z0-9_]*)'"]
    for message in errorMessages {
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = message as NSString
            for m in re.matches(in: message, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                if swiftBasics.contains(name) { continue }
                if seen.insert(name).inserted { names.append(name) }
            }
        }
    }
    var results: [(name: String, excerpt: String)] = []
    for name in names.prefix(4) {
        let cmd = "grep -rhE -A 30 '(class|struct|enum|protocol|extension|actor) \(name)\\b|@interface \(name)\\b' '\(sdk)/System/Library/Frameworks' --include='*.swiftinterface' --include='*.h' 2>/dev/null | head -80"
        let out = sh(cmd).output
        results.append((name, String(out.prefix(3000))))
    }
    return results
}

// MARK: - Main

func run() {
    let opts = parseArgs(CommandLine.arguments)
    let targetName = (opts.file as NSString).lastPathComponent
    var previousErrors: Set<String>? = nil
    for r in 1...opts.maxRounds {
        let (status, output) = sh(opts.build)
        let errors = parseErrors(output: output, targetName: targetName)
        if errors.isEmpty && status == 0 {
            print("compiled after \(r - 1) fix rounds")
            exit(0)
        }
        if status != 0 && errors.isEmpty {
            let lines = stripANSI(output).split(separator: "\n").map(String.init)
            for line in lines.suffix(20) { print(line) }
            exit(1)
        }
        let errorSet = Set(errors.map(\.key))
        if let prev = previousErrors, prev == errorSet {
            print("same errors twice; stopping for a human")
            exit(1)
        }
        previousErrors = errorSet
        print("== round \(r): \(errors.count) errors")
        let facts = lspFacts(for: errors, filePath: opts.file)
        let sdk = sdkLookup(errorMessages: errors.map(\.message))
        var prompt = "\(targetName) fails to compile with: \(opts.build)\nErrors:\n"
        for e in errors { prompt += "\(e.line):\(e.col): \(e.message)\n" }
        prompt += "\nLSP facts at each error position (hover = real signature, completions = valid members):\n"
        for e in errors {
            let f = facts[e.key] ?? LSPFacts()
            prompt += "\(e.line):\(e.col) hover: \(f.hover)\n"
            prompt += "\(e.line):\(e.col) completions: \(f.completions)\n"
        }
        prompt += "\nSDK declarations:\n"
        for entry in sdk {
            prompt += "--- \(entry.name) ---\n\(entry.excerpt)\n"
        }
        prompt += "\nRead the file, fix each error with edit_file using only the APIs shown above, and change nothing else."
        let escapedPrompt = prompt.replacingOccurrences(of: "'", with: "'\\''")
        let botCmd = "\(opts.bot) --model '\(opts.model)' --max-steps 20 --file '\(opts.file)' '\(escapedPrompt)'"
        let botOut = sh(botCmd).output
        let botLines = botOut.split(separator: "\n").map(String.init)
        for line in botLines.suffix(3) { print(line) }
    }
    print("still failing after \(opts.maxRounds) rounds")
    exit(1)
}

@main
struct FixLoop {
    static func main() {
        run()
    }
}