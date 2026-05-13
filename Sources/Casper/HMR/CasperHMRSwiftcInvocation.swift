// CASPER: SwiftcInvocation parsing + normalization (Req 16). Pure functions —
// no I/O outside the response-file/filelist expansion that the spec mandates.
// Tested by CasperHMRArgvNormalizationTests + CasperHMRArgvMutationTests.

#if DEBUG

import Foundation

struct CasperHMRSwiftcInvocation {
    /// Normalized argv: response files expanded inline, `-filelist` expanded
    /// to individual paths, batch-mode multi-`-primary-file` collapsed to a
    /// single placeholder (filled in by `mutate(for:)`), captured xcodebuild
    /// `-o <path>` stripped, dependency-output flags stripped.
    let normalizedArgv: [String]

    /// Source files this invocation compiles, post-expansion.
    let files: [CasperHMRCanonicalPath]

    /// Working directory captured at wrapper time (`-working-directory` flag
    /// or `cwd` field from commands.jsonl). Daemon execs swiftc with this as
    /// cwd, not the daemon's PWD.
    let workingDirectory: String?

    /// Subset of captured xcodebuild env vars to replay (Req 19).
    let envSubset: [String: String]

    /// Per-record fingerprint fields (Req 20).
    let xcodeBuildVersion: String
    let wrapperVersion: String
    let pbxprojMtimeNS: Int64
    let buildSettingsHash: String
}

enum CasperHMRSwiftcInvocationError: Error {
    case malformedJSONLLine
    case missingFields
    case responseFileUnreadable(String)
    case filelistUnreadable(String)
}

enum CasperHMRSwiftcInvocationParser {
    /// Parse one JSONL line emitted by casper-swiftc-wrapper.
    static func parse(jsonlLine: Data) throws -> CasperHMRSwiftcInvocation {
        guard let obj = try? JSONSerialization.jsonObject(with: jsonlLine, options: []) as? [String: Any] else {
            throw CasperHMRSwiftcInvocationError.malformedJSONLLine
        }
        return try parse(record: obj)
    }

    static func parse(record obj: [String: Any]) throws -> CasperHMRSwiftcInvocation {
        guard let rawArgv = obj["argv"] as? [String] else {
            throw CasperHMRSwiftcInvocationError.missingFields
        }
        let envSubset = (obj["env_subset"] as? [String: String]) ?? [:]
        let workingDir = obj["cwd"] as? String

        let xcodeBuildVersion = (obj["xcode_build_version"] as? String) ?? ""
        let wrapperVersion = (obj["wrapper_version"] as? String) ?? ""
        let pbxprojMtimeNS = (obj["pbxproj_mtime_ns"] as? Int64)
            ?? Int64((obj["pbxproj_mtime_ns"] as? NSNumber)?.int64Value ?? 0)
        let buildSettingsHash = (obj["build_settings_hash"] as? String) ?? ""

        // Drop argv[0] (the wrapper's own program path captured by the
        // swiftc-wrapper). Leaving it in causes swift-frontend to treat it as a
        // positional input and choke trying to compile a Mach-O binary as
        // Swift source ("must be UTF-8 instead of UTF-16").
        let withoutArgv0 = Array(rawArgv.dropFirst())
        let expanded = try expandResponseFilesAndFilelists(withoutArgv0, cwd: workingDir)
        let stripped = stripCapturedOutputAndDependencyFlags(expanded)
        let withoutBatchPrimary = collapseBatchModePrimaryFiles(stripped)

        let files = extractSourceFiles(withoutBatchPrimary).map(CasperHMRCanonicalPath.init)

        return CasperHMRSwiftcInvocation(
            normalizedArgv: withoutBatchPrimary,
            files: files,
            workingDirectory: workingDir,
            envSubset: envSubset,
            xcodeBuildVersion: xcodeBuildVersion,
            wrapperVersion: wrapperVersion,
            pbxprojMtimeNS: pbxprojMtimeNS,
            buildSettingsHash: buildSettingsHash
        )
    }

    /// Inline-expand `@response.resp` args; expand `-filelist <path>` into
    /// individual source-file args. Other arg forms pass through.
    static func expandResponseFilesAndFilelists(_ argv: [String], cwd: String?) throws -> [String] {
        var result: [String] = []
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            if arg.hasPrefix("@") {
                let path = resolvePath(String(arg.dropFirst()), cwd: cwd)
                guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                    throw CasperHMRSwiftcInvocationError.responseFileUnreadable(path)
                }
                result.append(contentsOf: tokenizeResponseFile(contents))
            } else if arg == "-filelist", i + 1 < argv.count {
                let path = resolvePath(argv[i + 1], cwd: cwd)
                guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                    throw CasperHMRSwiftcInvocationError.filelistUnreadable(path)
                }
                let entries = contents.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                result.append(contentsOf: entries)
                i += 1 // skip the filelist path
            } else {
                result.append(arg)
            }
            i += 1
        }
        return result
    }

    /// Strip the captured xcodebuild `-o <build-graph-path>` (we install our
    /// own) and dependency-output flags that would write into build-graph
    /// paths.
    static func stripCapturedOutputAndDependencyFlags(_ argv: [String]) -> [String] {
        var result: [String] = []
        var i = 0
        let pairedFlags: Set<String> = [
            "-o",
            "-emit-dependencies-path",
            "-emit-reference-dependencies-path",
            "-serialize-diagnostics-path",
            "-emit-module-path",
            "-emit-module-doc-path",
            "-emit-module-source-info-path",
            "-emit-objc-header-path",
            "-emit-tbd-path",
            "-output-file-map",
            "-index-store-path",
            "-index-unit-output-path",
            "-emit-loaded-module-trace-path",
        ]
        while i < argv.count {
            let arg = argv[i]
            if pairedFlags.contains(arg), i + 1 < argv.count {
                i += 2
                continue
            }
            result.append(arg)
            i += 1
        }
        return result
    }

    /// Drop pre-existing `-primary-file <path>` pairs; daemon installs its own
    /// single-file primary in `mutate(for:)`. Also drops batch-mode duplicates.
    static func collapseBatchModePrimaryFiles(_ argv: [String]) -> [String] {
        var result: [String] = []
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            if arg == "-primary-file", i + 1 < argv.count {
                i += 2
                continue
            }
            result.append(arg)
            i += 1
        }
        return result
    }

    private static func tokenizeResponseFile(_ contents: String) -> [String] {
        // Apple's swift-driver writes response files with one quoted-or-bare
        // token per whitespace-separated chunk. Quotes use double-quote +
        // backslash escape.
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var escape = false
        for c in contents {
            if escape {
                current.append(c)
                escape = false
                continue
            }
            if c == "\\" {
                escape = true
                continue
            }
            if c == "\"" {
                inQuotes.toggle()
                continue
            }
            if c.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(c)
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func resolvePath(_ path: String, cwd: String?) -> String {
        if path.hasPrefix("/") { return path }
        let base = cwd ?? FileManager.default.currentDirectoryPath
        return "\(base)/\(path)"
    }

    /// Heuristic for extracting positional source-file args from already-
    /// normalized argv. Used to populate `files` on the parsed invocation.
    static func extractSourceFiles(_ argv: [String]) -> [String] {
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
}

// MARK: - Mutation

extension CasperHMRSwiftcInvocation {
    /// Produce the compile argv for a single-file primary-file pass. The
    /// daemon invokes `swift -frontend -c` (not `swiftc`) because the modern
    /// swift-driver no longer accepts `-primary-file` as a driver-level flag
    /// for our shape (warns "save unknown driver flag" and tries to emit one
    /// .o per input, then fails with "cannot specify -o when generating
    /// multiple output files"). Going through the frontend directly is the
    /// canonical way to compile one file as primary while type-checking
    /// against the rest of the module.
    ///
    /// Returned argv is intended to be appended to `[swiftFrontendPath,
    /// "-frontend"]`. Compile pipeline: drop `savedFile` from positional
    /// inputs, translate the captured driver argv to a frontend-compatible
    /// argv (collapsing `-Xfrontend X` pairs, stripping driver-only flags),
    /// then prepend `-c -primary-file <savedFile>` and append `-o <objPath>`.
    func compileArgv(savedFile: String, objectPath: String) -> [String] {
        let translated = CasperHMRSwiftcInvocation.translateToFrontendArgv(normalizedArgv)
        let auxiliary = CasperHMRSwiftcInvocation.removingPositionalInput(savedFile, from: translated)
        return ["-c", "-primary-file", savedFile] + auxiliary + ["-o", objectPath]
    }

    /// Produce a planned compile argv with the `-o` placeholder set to
    /// `$HASH$.o` instead of the on-disk path. Used by Req 6's content-
    /// addressed hash so the hash is free of build-graph-specific paths.
    func hashCompileArgv(savedFile: String) -> [String] {
        let translated = CasperHMRSwiftcInvocation.translateToFrontendArgv(normalizedArgv)
        let auxiliary = CasperHMRSwiftcInvocation.removingPositionalInput(savedFile, from: translated)
        return ["-c", "-primary-file", savedFile] + auxiliary + ["-o", "$HASH$.o"]
    }

    /// Translate the captured driver-level argv into one the frontend will
    /// accept. Two transformations:
    ///   1. Collapse `-Xfrontend X` pairs into bare `X` (these pairs are the
    ///      driver's pass-through mechanism; the frontend sees them as bare
    ///      flags).
    ///   2. Strip flags that only exist at the driver level. The frontend
    ///      errors on these with "unknown argument". The set is empirical
    ///      from Xcode 26.5's swiftc output for our cmux DEV target.
    static func translateToFrontendArgv(_ argv: [String]) -> [String] {
        var collapsed: [String] = []
        collapsed.reserveCapacity(argv.count)
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a == "-Xfrontend", i + 1 < argv.count {
                collapsed.append(argv[i + 1])
                i += 2
                continue
            }
            collapsed.append(a)
            i += 1
        }

        let driverOnlySingle: Set<String> = [
            "-parseable-output",
            "-emit-const-values",
            "-incremental",
            "-driver-show-incremental",
            "-enable-batch-mode",
            "-disable-batch-mode",
        ]
        let driverOnlyPaired: Set<String> = [
            "-j",
            "-driver-batch-count",
            "-driver-filelist-threshold",
            "-driver-batch-size-limit",
            "-working-directory",
        ]

        var result: [String] = []
        result.reserveCapacity(collapsed.count)
        i = 0
        while i < collapsed.count {
            let a = collapsed[i]
            if driverOnlyPaired.contains(a), i + 1 < collapsed.count {
                i += 2
                continue
            }
            if driverOnlySingle.contains(a) {
                i += 1
                continue
            }
            // Stuck-form `-j18` etc. — same family as the paired `-j N`.
            if a.hasPrefix("-j"), a != "-j" {
                i += 1
                continue
            }
            result.append(a)
            i += 1
        }
        return result
    }

    /// Returns argv with the first positional occurrence of `path` removed.
    /// Compares by canonicalized absolute path (resolving symlinks + normalizing
    /// `..`/`.`) so a relative entry in the SwiftFileList still matches the
    /// absolute `savedFile` we get from FSEvents.
    static func removingPositionalInput(_ path: String, from argv: [String]) -> [String] {
        let target = canonicalize(path)
        var result: [String] = []
        result.reserveCapacity(argv.count)
        var skipped = false
        for arg in argv {
            if !skipped, arg.hasSuffix(".swift"), !arg.hasPrefix("-"),
               canonicalize(arg) == target {
                skipped = true
                continue
            }
            result.append(arg)
        }
        return result
    }

    private static func canonicalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Produce the link argv: `swiftc -emit-library -Xlinker -dylib …` plus
    /// scraped flags from the original compile argv (Req 17). Returns the
    /// real argv (with the daemon-private `-o` filled in).
    func linkArgv(objectPath: String, dylibPath: String) -> [String] {
        return baseLinkArgvSkeleton() + [
            objectPath,
            "-o", dylibPath,
        ]
    }

    /// Same shape as `linkArgv` but with the `-o` value replaced by the literal
    /// `"$HASH$.dylib"`. Feeds Req 6's hash computation so the hash is build-
    /// graph independent.
    func hashLinkArgv() -> [String] {
        return baseLinkArgvSkeleton() + [
            "$HASH$.o",
            "-o", "$HASH$.dylib",
        ]
    }

    private func baseLinkArgvSkeleton() -> [String] {
        var args: [String] = [
            "-emit-library",
            "-Xlinker", "-dylib",
            "-Xlinker", "-undefined",
            "-Xlinker", "dynamic_lookup",
        ]
        args.append(contentsOf: scrapedLinkFlags())
        return args
    }

    private func scrapedLinkFlags() -> [String] {
        // Per Req 17, scrape: -target, -arch, -isysroot, -mmacosx-version-min,
        // all -F/-framework/-weak_framework/-L/-l/-rpath, all SPM product
        // library -l entries.
        var result: [String] = []
        var i = 0
        let pairedFlags: Set<String> = [
            "-target",
            "-arch",
            "-isysroot",
            "-mmacosx-version-min",
            "-F",
            "-framework",
            "-weak_framework",
            "-L",
            "-l",
            "-rpath",
            "-sdk",
        ]
        while i < normalizedArgv.count {
            let arg = normalizedArgv[i]
            if pairedFlags.contains(arg), i + 1 < normalizedArgv.count {
                result.append(arg)
                result.append(normalizedArgv[i + 1])
                i += 2
                continue
            }
            // Stuck-form -F/-L/-l (e.g. "-Lpath", "-lname") are also valid.
            if arg.hasPrefix("-L") || arg.hasPrefix("-l") || arg.hasPrefix("-F") {
                if arg.count > 2 {
                    result.append(arg)
                    i += 1
                    continue
                }
            }
            i += 1
        }
        // Canonicalize order: sort repeatable flag groups so flag-order churn
        // doesn't bust Req 6's hash. We do this by grouping each (flag, value)
        // pair and sorting by the value within each flag.
        return canonicalizeFlagOrder(result)
    }

    private func canonicalizeFlagOrder(_ flags: [String]) -> [String] {
        var pairs: [(String, String)] = []
        var i = 0
        while i < flags.count {
            if i + 1 < flags.count {
                pairs.append((flags[i], flags[i + 1]))
                i += 2
            } else {
                pairs.append((flags[i], ""))
                i += 1
            }
        }
        let sorted = pairs.sorted { lhs, rhs in
            if lhs.0 == rhs.0 { return lhs.1 < rhs.1 }
            return lhs.0 < rhs.0
        }
        var out: [String] = []
        for (flag, value) in sorted {
            out.append(flag)
            if !value.isEmpty { out.append(value) }
        }
        return out
    }
}

#endif
