// CASPER: swiftc shim invoked via SWIFT_EXEC during Debug builds. Always writes a
// JSONL entry to ~/.casper/hmr/<tag>/commands.jsonl (per Req 2), then execs the
// real swiftc unchanged. Filtering Casper-vs-non-Casper sources happens at
// daemon startup, not here. Delete this whole tool once upstream cmux ships an
// in-process HMR story.

import Foundation
import Darwin
import CryptoKit

let wrapperVersion = "1.0.0"
let schemaVersion = 1

// Allowlist of environment variables we capture into commands.jsonl so the
// daemon can replay swiftc with the same module-cache/SDK settings xcodebuild
// originally injected. Misses surface as "module not found" at recompile and
// are added iteratively. Keep in sync with Req 19.
let allowlistedEnvKeys: Set<String> = [
    "DEVELOPER_DIR",
    "SDKROOT",
    "TOOLCHAINS",
    "PATH",
    "HOME",
    "TMPDIR",
    "SOURCE_ROOT",
    "BUILT_PRODUCTS_DIR",
    "OBJROOT",
    "SYMROOT",
    "MODULE_CACHE_DIR",
    "SWIFT_MODULE_CACHE_PATH",
    "CLANG_MODULE_CACHE_PATH",
    "LANG",
    "LC_ALL",
]

// Regex-style prefix allowlist: anything matching SWIFT_, XCODE_, DT_ is in.
let allowlistedEnvPrefixes: [String] = ["SWIFT_", "XCODE_", "DT_"]

func capturedEnvSubset() -> [String: String] {
    var result: [String: String] = [:]
    let env = ProcessInfo.processInfo.environment
    for (key, value) in env {
        if allowlistedEnvKeys.contains(key) {
            result[key] = value
            continue
        }
        for prefix in allowlistedEnvPrefixes where key.hasPrefix(prefix) {
            result[key] = value
            break
        }
    }
    return result
}

// `~/.casper/hmr/<tag>/` — the tag slug arrives from CASPER_HMR_TAG, set by
// reload.sh. Missing → "agent" (the build-time fallback sentinel). Daemon
// refuses to start under "agent", but build-time writes are still funneled
// into the sentinel dir to avoid `~/.casper/hmr//commands.jsonl`.
func stateDirectory() -> String {
    let env = ProcessInfo.processInfo.environment
    let tag = env["CASPER_HMR_TAG"] ?? "agent"
    let home = env["HOME"] ?? NSHomeDirectory()
    return "\(home)/.casper/hmr/\(tag)"
}

func ensureDirectoryExists(_ path: String) {
    try? FileManager.default.createDirectory(
        atPath: path,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
}

// Resolve real swiftc via xcrun. Cache result by DEVELOPER_DIR to avoid the
// xcrun cost on every invocation. DEVELOPER_DIR is the canonical key (xcrun
// itself does not consult SWIFT_EXEC; we scrub it from the child env anyway
// for defense).
func resolveRealSwiftc() -> String? {
    let env = ProcessInfo.processInfo.environment
    let home = env["HOME"] ?? NSHomeDirectory()
    let developerDir = env["DEVELOPER_DIR"] ?? "default"
    let cacheDir = "\(home)/.casper/hmr/tools/cache"
    let cacheKey = developerDir.replacingOccurrences(of: "/", with: "_")
    let cachePath = "\(cacheDir)/real-swiftc-\(cacheKey)"

    if let cached = try? String(contentsOfFile: cachePath, encoding: .utf8) {
        let trimmed = cached.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) {
            return trimmed
        }
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--find", "swiftc"]
    var scrubbedEnv = env
    scrubbedEnv.removeValue(forKey: "SWIFT_EXEC")
    process.environment = scrubbedEnv
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let str = String(data: data, encoding: .utf8) else { return nil }
    let path = str.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
        return nil
    }
    try? FileManager.default.createDirectory(
        atPath: cacheDir,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try? path.write(toFile: cachePath, atomically: true, encoding: .utf8)
    return path
}

// Parse argv for primary-source files. We capture this list so the daemon can
// later filter Casper-vs-non-Casper invocations. We do NOT expand response
// files or filelists in the wrapper — that's the daemon's job (Req 2).
//
// Heuristic: any positional arg ending in `.swift` is a source file. This is
// over-permissive (some flag arguments could also end in `.swift`), but the
// daemon re-parses argv with full normalization and uses the structured result
// — `files` here is a coarse capture hint.
func extractSourceFiles(_ argv: [String]) -> [String] {
    var result: [String] = []
    var i = 0
    while i < argv.count {
        let arg = argv[i]
        if arg.hasSuffix(".swift") && !arg.hasPrefix("-") {
            result.append(arg)
        }
        i += 1
    }
    return result
}

// xcodebuild -version output: "Xcode 16.x\nBuild version 16Xnnn" — the last
// line is the build version, the unique fingerprint we care about.
func xcodeBuildVersion() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--show-sdk-build-version"]
    process.environment = ProcessInfo.processInfo.environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return "unknown" }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? "unknown"
}

func sdkrootRealPath() -> String {
    let env = ProcessInfo.processInfo.environment
    guard let sdkroot = env["SDKROOT"] else { return "" }
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    if realpath(sdkroot, &buf) != nil {
        return String(cString: buf)
    }
    return sdkroot
}

func pbxprojMtimeNS() -> Int64 {
    let env = ProcessInfo.processInfo.environment
    let sourceRoot = env["SOURCE_ROOT"] ?? env["SRCROOT"] ?? FileManager.default.currentDirectoryPath
    let pbxprojPath = "\(sourceRoot)/GhosttyTabs.xcodeproj/project.pbxproj"
    var st = stat()
    guard stat(pbxprojPath, &st) == 0 else { return 0 }
    return Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
}

func buildSettingsHash(_ envSubset: [String: String]) -> String {
    // SHA-256 over sorted key=value pairs. Cheap, stable, and surfaces
    // toolchain/setting drift between the build that captured the argv and the
    // daemon trying to replay it.
    let sorted = envSubset.sorted { $0.key < $1.key }
    let joined = sorted.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1f}")
    guard let data = joined.data(using: .utf8) else { return "" }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

func jsonEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count + 2)
    for c in s {
        switch c {
        case "\\": out.append("\\\\")
        case "\"": out.append("\\\"")
        case "\n": out.append("\\n")
        case "\r": out.append("\\r")
        case "\t": out.append("\\t")
        case "\u{08}": out.append("\\b")
        case "\u{0c}": out.append("\\f")
        default:
            let scalar = c.unicodeScalars.first!.value
            if scalar < 0x20 {
                out.append(String(format: "\\u%04x", scalar))
            } else {
                out.append(c)
            }
        }
    }
    return out
}

func jsonString(_ s: String) -> String {
    return "\"\(jsonEscape(s))\""
}

func jsonStringArray(_ arr: [String]) -> String {
    return "[" + arr.map { jsonString($0) }.joined(separator: ",") + "]"
}

func jsonStringObject(_ dict: [String: String]) -> String {
    let sortedKeys = dict.keys.sorted()
    let parts = sortedKeys.map { "\(jsonString($0)):\(jsonString(dict[$0] ?? ""))" }
    return "{" + parts.joined(separator: ",") + "}"
}

// flock(LOCK_EX) on a separate `.lock` file, then O_APPEND write to
// commands.jsonl. POSIX only guarantees small-write atomicity for pipes; XNU's
// regular-file behavior is reliable in practice but not contractual, so we
// flock unconditionally. Cost is negligible at swiftc-invocation frequency.
func appendJSONL(line: String, statePath: String) {
    let jsonlPath = "\(statePath)/commands.jsonl"
    let lockPath = "\(statePath)/commands.jsonl.lock"

    let lockFd = open(lockPath, O_CREAT | O_WRONLY, 0o600)
    guard lockFd >= 0 else { return }
    defer { close(lockFd) }
    if flock(lockFd, LOCK_EX) != 0 {
        return
    }
    defer { _ = flock(lockFd, LOCK_UN) }

    let fd = open(jsonlPath, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard fd >= 0 else { return }
    defer { close(fd) }
    let withNewline = line + "\n"
    withNewline.withCString { cstr in
        _ = write(fd, cstr, strlen(cstr))
    }
}

// MARK: - Entrypoint

let argv = CommandLine.arguments
let env = ProcessInfo.processInfo.environment

// Recursion guard — if a parent wrapper invocation already set this, skip the
// JSONL append entirely (no-op, just exec). Defends against build-system
// layers that might re-inject SWIFT_EXEC into a child swiftc invocation.
let alreadyActive = env["CASPER_SWIFTC_WRAPPER_ACTIVE"] == "1"

if !alreadyActive {
    let statePath = stateDirectory()
    ensureDirectoryExists(statePath)

    let envSubset = capturedEnvSubset()
    let files = extractSourceFiles(argv)
    let cwd = env["PWD"] ?? FileManager.default.currentDirectoryPath
    let tag = env["CASPER_HMR_TAG"] ?? "agent"
    let ts = Date().timeIntervalSince1970

    var line = "{"
    line += "\"schema\":\(schemaVersion)"
    line += ",\"ts\":\(String(format: "%.6f", ts))"
    line += ",\"tag\":\(jsonString(tag))"
    line += ",\"cwd\":\(jsonString(cwd))"
    line += ",\"files\":\(jsonStringArray(files))"
    line += ",\"argv\":\(jsonStringArray(argv))"
    line += ",\"env_subset\":\(jsonStringObject(envSubset))"
    line += ",\"xcode_build_version\":\(jsonString(xcodeBuildVersion()))"
    line += ",\"sdkroot_real_path\":\(jsonString(sdkrootRealPath()))"
    line += ",\"wrapper_version\":\(jsonString(wrapperVersion))"
    line += ",\"pbxproj_mtime_ns\":\(pbxprojMtimeNS())"
    line += ",\"build_settings_hash\":\(jsonString(buildSettingsHash(envSubset)))"
    line += "}"

    appendJSONL(line: line, statePath: statePath)
}

// Resolve the real swiftc and exec.
guard let realSwiftc = resolveRealSwiftc() else {
    fputs("casper-swiftc-wrapper: failed to resolve real swiftc via xcrun\n", stderr)
    exit(127)
}

// Build child env: drop SWIFT_EXEC (so the child's own driver invocations
// don't loop back through us), set CASPER_SWIFTC_WRAPPER_ACTIVE=1.
var childEnv = env
childEnv.removeValue(forKey: "SWIFT_EXEC")
childEnv["CASPER_SWIFTC_WRAPPER_ACTIVE"] = "1"

// execve replaces this process. argv is passed through unchanged — the wrapper
// never mutates compile flags.
let cArgs: [UnsafeMutablePointer<CChar>?] =
    ([realSwiftc] + argv.dropFirst()).map { strdup($0) } + [nil]
let cEnv: [UnsafeMutablePointer<CChar>?] =
    childEnv.map { strdup("\($0.key)=\($0.value)") } + [nil]

cArgs.withUnsafeBufferPointer { argsBuf in
    cEnv.withUnsafeBufferPointer { envBuf in
        _ = execve(realSwiftc, argsBuf.baseAddress, envBuf.baseAddress)
    }
}
// execve only returns on failure.
fputs("casper-swiftc-wrapper: execve failed errno=\(errno)\n", stderr)
exit(127)
