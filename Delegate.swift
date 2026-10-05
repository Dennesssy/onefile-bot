// Delegate.swift — one onefile-bot per folder, each allowed to write only that folder's assigned files.
//
// Reads a file-tree CSV (columns: path,name,type,purpose,requirement,layer,plane,platform,status; `path`
// relative to --root), groups the missing files by folder, and runs folders in dependency waves
// (contracts → data/config → core → server → execution node → tests → deploy → docs). Folders within a
// wave run in parallel (--jobs). Each bot gets: its folder's files (as --file, nothing else writable),
// each file's purpose and requirement, the folder's row, and related existing files as read-only --context.
//
// Usage:
//   delegate --tree tree.csv --root REPO [--wave N|all] [--jobs 4] [--bot ./onefile-bot]
//            [--model qwen/qwen3.8-27b] [--overwrite] [--dry-run]
// Build: swiftc -O -parse-as-library Delegate.swift -o delegate

import Foundation

struct Row: Sendable {
    let path, type, purpose, requirement, plane, platform, status: String
    var folder: String { (path as NSString).deletingLastPathComponent }
    var ext: String { (path as NSString).pathExtension }
}

struct Options: Sendable {
    var tree = "", root = "", wave = "all", folder = ""
    var models = ["qwen/qwen3.8-27b", "openai/gpt-oss-120b"]  // alternated per folder: separate rate limits
    var bot = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("onefile-bot").path
    var jobs = 4
    var overwrite = false, dryRun = false
}

let waves: [(Int, String, @Sendable (String) -> Bool)] = [
    (1, "contracts", { $0.hasPrefix("proto/") }),
    (2, "data and config", { $0.hasPrefix("db/") || $0.hasPrefix("config/") }),
    (3, "core library", { $0.hasPrefix("Sources/AgenticGatewayCore/") }),
    (4, "server, CLI, SDK", { $0.hasPrefix("Sources/") }),
    (5, "execution node", { $0.hasPrefix("ExecutionNode/") }),
    (6, "tests", { $0.hasPrefix("Tests/") }),
    (7, "deploy, tooling, integrations, clients",
        { ["docker/", "deploy/", "scripts/", "integrations/", "clients/"].contains(where: $0.hasPrefix) }),
    (8, "docs and top-level", { _ in true }),
]

func waveOf(_ path: String) -> Int { waves.first { $0.2(path) }!.0 }

let jsFeatures = ["Temporal", "BigInt", "Iterator Chunking", "JSON Source Text Access", "Async Stack Traces"]

// MARK: - CSV

func parseCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
    var chars = Array(text).makeIterator()
    while let c = chars.next() {
        if quoted {
            if c == "\"" {
                if let n = chars.next() {
                    if n == "\"" { field.append("\"") } else {
                        quoted = false
                        if n == "," { row.append(field); field = "" }
                        else if n == "\n" || n == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
                        else { field.append(n) }
                    }
                } else { quoted = false }
            } else { field.append(c) }
        } else if c == "\"" { quoted = true }
        else if c == "," { row.append(field); field = "" }
        else if c == "\n" || c == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
        else if c != "\r" { field.append(c) }
    }
    if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
    return rows
}

func loadRows(_ path: String) throws -> [Row] {
    let table = parseCSV(try String(contentsOfFile: path, encoding: .utf8))
    guard let header = table.first else { return [] }
    func col(_ name: String) throws -> Int {
        guard let i = header.firstIndex(of: name) else {
            throw NSError(domain: "delegate", code: 1, userInfo: [NSLocalizedDescriptionKey: "CSV has no \(name) column"])
        }
        return i
    }
    let (p, t, pu, re, pl, pf, st) = try (col("path"), col("type"), col("purpose"), col("requirement"),
                                          col("plane"), col("platform"), col("status"))
    return table.dropFirst().filter { $0.count == header.count }.map {
        Row(path: $0[p], type: $0[t], purpose: $0[pu], requirement: $0[re], plane: $0[pl], platform: $0[pf], status: $0[st])
    }
}

// MARK: - Validation

func sh(_ command: String, cwd: String? = nil) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", command]
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Returns (check command, error text) for a file that fails its type's check, or nil when it passes
/// (or has no check). Errors are the first lines that mention the file.
func validate(_ path: String, root: String) -> (check: String, errors: String)? {
    let name = (path as NSString).lastPathComponent
    let ext = (path as NSString).pathExtension
    let full = (root as NSString).appendingPathComponent(path)
    let check: String
    var cwd: String? = nil
    switch ext {
    case "swift": check = "xcrun swiftc -parse \(q(full))"
    case "proto": check = "protoc -I . --descriptor_set_out=/dev/null \(q(String(path.dropFirst("proto/".count))))"
                  cwd = (root as NSString).appendingPathComponent("proto")
    case "json": check = "/usr/bin/python3 -m json.tool \(q(full)) > /dev/null"
    case "yaml", "yml": check = "ruby -ryaml -e 'YAML.load_stream(File.read(ARGV[0]))' \(q(full))"
    case "sh": check = "bash -n \(q(full))"
    case "plist": check = "plutil -lint \(q(full))"
    case "py": check = "/usr/bin/python3 -m py_compile \(q(full))"
    default: return nil
    }
    if ext == "yaml" || ext == "yml", full.contains("/templates/") { return nil }  // Helm templates aren't plain YAML
    let (status, output) = sh(check, cwd: cwd)
    let clean = output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    let hasError = ext == "swift" ? clean.contains("error:") : status != 0
    guard hasError else { return nil }
    let lines = clean.split(separator: "\n").filter { $0.contains(name) || ext != "swift" }
        .filter { ext != "swift" || $0.contains(": error:") }
    return (check, lines.prefix(15).joined(separator: "\n"))
}

// MARK: - Per-folder job

struct Job: Sendable {
    let folder: String
    var model = ""
    let files: [Row]
    let context: [String]
    let prompt: String
}

func contextFiles(for files: [Row], all: [Row], root: String) -> [String] {
    let exts = Set(files.map(\.ext))
    var picks: [String] = []
    if exts.contains("swift") { picks += ["Package.swift", "proto/agentic/gateway/v1/common.proto"] }
    if exts.contains("proto") { picks.append("proto/agentic/gateway/v1/common.proto") }
    if exts.contains("sql") { picks.append("db/migrations/001_initial.sql") }
    let folder = files[0].folder
    let assigned = Set(files.map(\.path))
    picks += all.filter { $0.type == "file" && $0.folder == folder && !assigned.contains($0.path) && exts.contains($0.ext) }
        .map(\.path).sorted()
    var out: [String] = [], total = 0, seen = Set<String>()
    for p in picks where seen.insert(p).inserted && !assigned.contains(p) {
        let full = (root as NSString).appendingPathComponent(p)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: full))?[.size] as? Int,
              size > 0, total + size <= 60_000, out.count < 6 else { continue }
        out.append(full)
        total += size
    }
    return out
}

func promptFor(files: [Row], all: [Row]) -> String {
    let folder = files[0].folder
    var lines = [
        "You are writing the files of ONE folder in the agentic-gateway monorepo: a Swift package with a governance "
        + "plane (gateway server), an execution plane (Mac ExecutionNode) and a management plane (CRUD APIs).",
        "Folder: \(folder)/",
    ]
    if let parent = all.first(where: { $0.type == "dir" && $0.path == folder }) {
        lines.append("Folder purpose: \(parent.purpose) \(parent.requirement)")
    }
    lines += ["", "Write every one of these files (all of them, each complete):"]
    for f in files {
        lines.append("- \((f.path as NSString).lastPathComponent): \(f.purpose) Requirement: \(f.requirement) "
                     + "[plane \(f.plane), platform \(f.platform), status \(f.status)]")
    }
    lines += [
        "", "Rules:",
        "- Complete, working files. No placeholder bodies, no TODO stubs, no '...'.",
        "- Files in this folder must agree with each other: define each shared type once, in the file whose "
        + "purpose owns it, and reuse it from the others.",
        "- Stay consistent with the read-only reference files: reuse their type, message and field names.",
        "- For each file: write_file the first section, then append_file the rest in order.",
    ]
    if files.contains(where: { $0.ext == "swift" }) {
        lines.append("- Swift 6 with strict concurrency (Sendable types, actors for shared mutable state). Use Foundation "
                     + "and only packages declared in the reference Package.swift.")
        if files.contains(where: { $0.platform == "mac" || $0.status == "macos-only" }) {
            lines.append("- Files marked platform mac or status macos-only: wrap their contents in #if os(macOS) ... #endif.")
        }
    }
    if files.contains(where: { $0.ext == "proto" }) {
        lines.append("- proto3; package agentic.gateway.v1 (management files: agentic.gateway.v1.management); "
                     + "options matching the reference common.proto.")
    }
    if files.contains(where: { f in jsFeatures.contains(where: f.requirement.contains) }) {
        lines.append("- Some requirements name JavaScript language features Swift does not have (Temporal, BigInt, "
                     + "Iterator Chunking, JSON Source Text Access, Async Stack Traces). Implement their intent with "
                     + "Swift equivalents and add a one-line comment naming the JavaScript feature referred to.")
    }
    return lines.joined(separator: "\n")
}

// MARK: - Process

func runBot(files targets: [String], context: [String], prompt: String, model: String, steps: Int,
            o: Options, log: String) async -> Int32 {
    var args: [String] = []
    for t in targets { args += ["--file", t] }
    for c in context { args += ["--context", c] }
    args += ["--model", model, "--max-steps", String(steps), prompt]
    let fm = FileManager.default
    if !fm.fileExists(atPath: log) { fm.createFile(atPath: log, contents: nil) }
    let handle = FileHandle(forWritingAtPath: log)
    handle?.seekToEndOfFile()
    handle?.write(Data(("\n$ \(o.bot) " + args.dropLast().joined(separator: " ") + " <prompt>\n\(prompt)\n--- run ---\n").utf8))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: o.bot)
    process.arguments = args
    process.standardOutput = handle
    process.standardError = handle
    let status: Int32 = await withCheckedContinuation { cont in
        process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
        do { try process.run() } catch {
            handle?.write(Data("failed to start bot: \(error)\n".utf8))
            process.terminationHandler = nil
            cont.resume(returning: -1)
        }
    }
    try? handle?.close()
    return status
}

let batchSize = 4
let fixRounds = 2

/// One folder: batches of `batchSize` files written in order (each batch sees the earlier ones as
/// context), each followed by validation and up to `fixRounds` single-file fix rounds per failing file.
func runFolder(_ job: Job, _ o: Options, all: [Row], logsDir: String) async
    -> (written: Int, valid: Int, exit: Int32, seconds: Int, log: String) {
    let start = Date()
    let log = (logsDir as NSString).appendingPathComponent(job.folder.replacingOccurrences(of: "/", with: "__") + ".log")
    // Logs are appended across runs so every assignment stays on record.
    try? FileManager.default.createDirectory(
        atPath: (o.root as NSString).appendingPathComponent(job.folder), withIntermediateDirectories: true)
    var lastExit: Int32 = 0
    for batchStart in stride(from: 0, to: job.files.count, by: batchSize) {
        let batch = Array(job.files[batchStart..<min(batchStart + batchSize, job.files.count)])
        let targets = batch.map { (o.root as NSString).appendingPathComponent($0.path) }
        lastExit = await runBot(files: targets, context: contextFiles(for: batch, all: all, root: o.root),
                                prompt: promptFor(files: batch, all: all), model: job.model,
                                steps: 12 + 15 * batch.count, o: o, log: log)
        for f in batch {
            for round in 1...fixRounds {
                guard fileSize((o.root as NSString).appendingPathComponent(f.path)) > 0,
                      let failure = validate(f.path, root: o.root) else { break }
                let prompt = "\((f.path as NSString).lastPathComponent) fails its check (\(failure.check)) with:\n"
                    + "\(failure.errors)\n\nRead the file and fix every error with edit_file (or append_file if it is "
                    + "incomplete). Keep its purpose: \(f.purpose) Requirement: \(f.requirement)\nThis is fix round \(round)."
                _ = await runBot(files: [(o.root as NSString).appendingPathComponent(f.path)],
                                 context: contextFiles(for: [f], all: all, root: o.root), prompt: prompt,
                                 model: job.model, steps: 16, o: o, log: log)
            }
        }
    }
    let written = job.files.filter { fileSize((o.root as NSString).appendingPathComponent($0.path)) > 0 }
    let valid = written.filter { validate($0.path, root: o.root) == nil }.count
    return (written.count, valid, lastExit, Int(Date().timeIntervalSince(start)), log)
}

func fileSize(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
}

func run(_ job: Job, _ o: Options, logsDir: String) async -> (written: Int, exit: Int32, seconds: Int, log: String) {
    let fm = FileManager.default
    let start = Date()
    let log = (logsDir as NSString).appendingPathComponent(job.folder.replacingOccurrences(of: "/", with: "__") + ".log")
    let targets = job.files.map { (o.root as NSString).appendingPathComponent($0.path) }
    try? fm.createDirectory(atPath: (targets[0] as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

    var args: [String] = []
    for t in targets { args += ["--file", t] }
    for c in job.context { args += ["--context", c] }
    args += ["--model", job.model, "--max-steps", String(12 + 15 * job.files.count), job.prompt]

    fm.createFile(atPath: log, contents: Data(("$ \(o.bot) " + args.dropLast().joined(separator: " ")
        + " <prompt>\n\n\(job.prompt)\n\n--- run ---\n").utf8))
    let handle = FileHandle(forWritingAtPath: log)
    handle?.seekToEndOfFile()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: o.bot)
    process.arguments = args
    process.standardOutput = handle
    process.standardError = handle
    let status: Int32 = await withCheckedContinuation { cont in
        process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
        do { try process.run() } catch {
            handle?.write(Data("failed to start bot: \(error)\n".utf8))
            process.terminationHandler = nil
            cont.resume(returning: -1)
        }
    }
    try? handle?.close()
    let written = targets.filter { ((try? fm.attributesOfItem(atPath: $0))?[.size] as? Int ?? 0) > 0 }.count
    return (written, status, Int(Date().timeIntervalSince(start)), log)
}

// MARK: - Main

func parseOptions() -> Options {
    var o = Options()
    var args = CommandLine.arguments.dropFirst()
    func usage() -> Never {
        FileHandle.standardError.write(Data(("usage: delegate --tree CSV --root REPO [--wave N|all] [--jobs N] "
            + "[--bot PATH] [--models A,B] [--folder PREFIX] [--overwrite] [--dry-run]\n").utf8))
        exit(2)
    }
    func value() -> String {
        guard let v = args.popFirst() else { usage() }
        return v
    }
    while let a = args.popFirst() {
        switch a {
        case "--tree": o.tree = value()
        case "--root": o.root = URL(fileURLWithPath: value()).standardizedFileURL.path
        case "--wave": o.wave = value()
        case "--jobs":
            guard let n = Int(value()) else { usage() }
            o.jobs = n
        case "--bot": o.bot = URL(fileURLWithPath: value()).standardizedFileURL.path
        case "--model", "--models": o.models = value().split(separator: ",").map(String.init)
        case "--folder": o.folder = value()
        case "--overwrite": o.overwrite = true
        case "--dry-run": o.dryRun = true
        default: usage()
        }
    }
    if o.tree.isEmpty || o.root.isEmpty || o.jobs < 1 { usage() }
    return o
}

@main
struct Delegate {
    static func main() async {
        let o = parseOptions()
        let rows: [Row]
        do { rows = try loadRows(o.tree) } catch { print("error: \(error.localizedDescription)"); exit(1) }
        let logsDir = (o.root as NSString).appendingPathComponent(".onefile-logs")
        try? FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)

        let selected = o.wave == "all" ? waves.map(\.0) : [Int(o.wave) ?? 0]
        var failures = 0, summary: [String] = []
        for (n, name, _) in waves where selected.contains(n) {
            let todo = rows.filter { $0.type == "file" && waveOf($0.path) == n && $0.path.hasPrefix(o.folder)
                && (o.overwrite || (((try? FileManager.default.attributesOfItem(
                    atPath: (o.root as NSString).appendingPathComponent($0.path)))?[.size] as? Int) ?? 0) == 0) }
            let jobs = Dictionary(grouping: todo, by: \.folder).sorted { $0.key < $1.key }.enumerated().map { i, entry in
                Job(folder: entry.key, model: o.models[i % o.models.count], files: entry.value,
                    context: contextFiles(for: entry.value, all: rows, root: o.root),
                    prompt: promptFor(files: entry.value, all: rows))
            }
            print("== wave \(n) (\(name)): \(todo.count) files in \(jobs.count) folders"); fflush(stdout)
            if o.dryRun {
                for j in jobs {
                    let ctx = j.context.map { String($0.dropFirst(o.root.count + 1)) }
                    print("   [\(j.model)] \(j.folder)/  files=\(j.files.map { ($0.path as NSString).lastPathComponent })  context=\(ctx)")
                }
                continue
            }
            await withTaskGroup(of: (Job, (written: Int, valid: Int, exit: Int32, seconds: Int, log: String)).self) { group in
                var pending = jobs.makeIterator()
                for _ in 0..<o.jobs {
                    guard let j = pending.next() else { break }
                    group.addTask { (j, await runFolder(j, o, all: rows, logsDir: logsDir)) }
                }
                for await (j, r) in group {
                    let allWritten = r.written == j.files.count
                    let allValid = allWritten && r.valid == j.files.count
                    let label = allValid ? "ok  " : (allWritten ? "chk " : "FAIL")  // chk: all written, some fail checks
                    if !allValid { failures += 1 }
                    print("   \(label) \(j.folder)/ [\(j.model)]  \(r.written)/\(j.files.count) written, \(r.valid) pass checks  \(r.seconds)s")
                    fflush(stdout)
                    summary.append("\(n),\(j.folder),\(j.files.count),\(r.written),\(r.valid),\(r.exit),\(r.seconds),\(r.log)")
                    if let next = pending.next() { group.addTask { (next, await runFolder(next, o, all: rows, logsDir: logsDir)) } }
                }
            }
        }
        if !summary.isEmpty {
            let path = (logsDir as NSString).appendingPathComponent("summary.csv")
            let header = FileManager.default.fileExists(atPath: path) ? "" : "wave,folder,assigned,written,valid,exit,seconds,log\n"
            let text = header + summary.joined(separator: "\n") + "\n"
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
            else { FileManager.default.createFile(atPath: path, contents: Data(text.utf8)) }
            print("done: \(summary.count - failures) folders ok, \(failures) with problems; logs in \(logsDir)")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
