// CASPER: Hot-reload daemon entrypoint (Req 4). Watches Sources/Casper/**.swift
// via FSEvents, recompiles changed files via the captured swiftc argv from
// ~/.casper/hmr/<tag>/commands.jsonl, links to a content-addressed .dylib,
// ad-hoc codesigns it, and dlopens it. The interpose section in the dylib
// makes existing call sites in the host code execute the new bodies on the
// next call.
//
// Spec: .claude/specs/casper-hmr.md. This file owns the FSEvents watcher,
// security gating, and the compile/link/sign/dlopen pipeline. Argv parsing is
// in CasperHMRSwiftcInvocation; classifier in CasperHMRSourceClassifier; UI
// in CasperHMRDebugWindow.
//
// Delete this whole file (along with the rest of Sources/Casper/HMR/) once
// upstream cmux ships an in-process HMR story.

#if DEBUG

import AppKit
import CoreServices
import CryptoKit
import Darwin
import Foundation
import MachO
import os.lock

// Build sentinel — embedded so Test #11's leak check can prove this code
// isn't present in Release builds. Forcing a `@used` attribute keeps the
// linker from dead-stripping it even when no caller references it.
@used let casperHMRBuildSentinel: String = CasperHMRConfig.buildSentinel

@MainActor
final class CasperHMRDaemon {
    static let shared = CasperHMRDaemon()

    private var enabled: Bool = false
    private var booted: Bool = false
    private var fsEventStream: FSEventStreamRef?
    private let compileQueue = DispatchQueue(label: "casper.hmr.compile", qos: .userInitiated)

    private var invocationByPath: [CasperHMRCanonicalPath: CasperHMRSwiftcInvocation] = [:]
    private var pendingCompiles: [CasperHMRCanonicalPath: DispatchWorkItem] = [:]
    private var previousHashByPath: [CasperHMRCanonicalPath: String] = [:]
    private var latencyWindow: [Double] = []

    private var repoRoot: String = ""
    private var tagSlug: String = ""
    private var defaultsObserverToken: NSObjectProtocol?

    private init() {}

    // MARK: - Boot

    /// Public entrypoint. Called from cmuxApp.init() in DEBUG builds.
    /// Idempotent — calling twice is a no-op.
    func boot() {
        guard !booted else { return }
        booted = true

        let env = ProcessInfo.processInfo.environment
        if env[CasperHMRConfig.environmentDisableKey] == "1" {
            cmuxDebugLog("casper.hmr.refused reason=env_disabled")
            return
        }

        guard refuseIfNotTagged() else { return }
        guard refuseIfProductionBundle() else { return }
        guard let resolvedRepoRoot = resolveAndValidateRepoRoot() else { return }
        repoRoot = resolvedRepoRoot
        guard refuseIfWrapperHostile() else { return }

        ensureStateDirectory()
        rewriteEventsJSONLForRetention()
        loadCommandsJSONL()
        wipeDylibsDirectory()

        installDefaultsObserver()
        readEnabledFromDefaults()

        if enabled {
            startFSEventsWatcher()
        }

        cmuxDebugLog("casper.hmr.boot.ok tag=\(tagSlug) repo_root=\(repoRoot) enabled=\(enabled) invocations=\(invocationByPath.count)")
    }

    // MARK: - Security gating

    private func refuseIfNotTagged() -> Bool {
        let env = ProcessInfo.processInfo.environment
        let raw = env["CASPER_HMR_TAG"] ?? ""
        guard !raw.isEmpty else {
            cmuxDebugLog("casper.hmr.refused reason=untagged")
            writeOneShotMissEvent(result: "miss_fingerprint", reason: "untagged")
            return false
        }
        guard raw.range(of: CasperHMRConfig.tagSlugRegex, options: .regularExpression) != nil else {
            cmuxDebugLog("casper.hmr.refused reason=tag_malformed tag=\(raw)")
            return false
        }
        guard raw != CasperHMRConfig.buildOnlyTagSentinel else {
            cmuxDebugLog("casper.hmr.refused reason=untagged tag=agent")
            return false
        }
        tagSlug = raw
        return true
    }

    private func refuseIfProductionBundle() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        if bundleID == CasperHMRConfig.productionBundleIdentifier {
            cmuxDebugLog("casper.hmr.refused reason=production_bundle bundle=\(bundleID)")
            return false
        }
        return true
    }

    private func resolveAndValidateRepoRoot() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["CMUXTERM_REPO_ROOT"], !raw.isEmpty else {
            cmuxDebugLog("casper.hmr.no_repo_root")
            writeOneShotMissEvent(result: "miss_repo_root", reason: "env_missing")
            return nil
        }
        let canonical = URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path
        let home = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory())
            .resolvingSymlinksInPath().standardizedFileURL.path
        let forbiddenPrefixes = ["/tmp", "/private/tmp", "/Applications", "/Library", "/System", "/Volumes"]
        for prefix in forbiddenPrefixes where canonical.hasPrefix(prefix + "/") || canonical == prefix {
            cmuxDebugLog("casper.hmr.refused reason=repo_root_outside_home root=\(canonical)")
            return nil
        }
        guard canonical.hasPrefix(home + "/") else {
            cmuxDebugLog("casper.hmr.refused reason=repo_root_outside_home root=\(canonical) home=\(home)")
            return nil
        }
        return canonical
    }

    private func refuseIfWrapperHostile() -> Bool {
        let path = CasperHMRConfig.wrapperBinaryPath()
        var st = stat()
        guard stat(path, &st) == 0 else {
            cmuxDebugLog("casper.hmr.refused reason=wrapper_missing path=\(path)")
            return false
        }
        if st.st_uid != geteuid() {
            cmuxDebugLog("casper.hmr.refused reason=wrapper_not_owned_by_user path=\(path) st_uid=\(st.st_uid) euid=\(geteuid())")
            return false
        }
        if (st.st_mode & S_IWOTH) != 0 {
            cmuxDebugLog("casper.hmr.refused reason=wrapper_world_writable path=\(path)")
            return false
        }
        return true
    }

    // MARK: - State dir

    private func ensureStateDirectory() {
        let dirs = [
            CasperHMRConfig.stateDirectory(),
            "\(CasperHMRConfig.stateDirectory())/dylibs",
        ]
        for dir in dirs {
            try? FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Repair drift on existing dirs.
            _ = chmod(dir, 0o700)
        }
    }

    private func rewriteEventsJSONLForRetention() {
        let path = "\(CasperHMRConfig.stateDirectory())/events.jsonl"
        guard FileManager.default.fileExists(atPath: path) else { return }
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = data.split(separator: "\n").map(String.init)
        let retention = CasperHMRConfig.eventsJSONLRetention
        let trimmed = lines.suffix(retention)
        let result = trimmed.joined(separator: "\n") + (trimmed.isEmpty ? "" : "\n")
        let tmpPath = "\(path).tmp.\(getpid())"
        do {
            try result.write(toFile: tmpPath, atomically: true, encoding: .utf8)
            _ = rename(tmpPath, path)
        } catch {
            cmuxDebugLog("casper.hmr.events_retention_fail err=\(error.localizedDescription)")
        }
    }

    private func wipeDylibsDirectory() {
        let dir = "\(CasperHMRConfig.stateDirectory())/dylibs"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for entry in entries {
            // Keep .o files for symbol-set extraction (Req 6 dylib-dir bounding).
            if entry.hasSuffix(".dylib") {
                try? FileManager.default.removeItem(atPath: "\(dir)/\(entry)")
            }
        }
    }

    // MARK: - commands.jsonl

    private func loadCommandsJSONL() {
        let path = "\(CasperHMRConfig.stateDirectory())/commands.jsonl"
        guard FileManager.default.fileExists(atPath: path) else {
            cmuxDebugLog("casper.hmr.commands_jsonl.missing path=\(path)")
            return
        }
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
        var byPath: [CasperHMRCanonicalPath: CasperHMRSwiftcInvocation] = [:]
        var fingerprintDriftDetected = false
        var firstXcodeBuild = ""
        var firstWrapperVersion = ""
        let lines = raw.split(separator: 0x0a)
        for line in lines {
            guard !line.isEmpty else { continue }
            guard let invocation = try? CasperHMRSwiftcInvocationParser.parse(jsonlLine: Data(line)) else {
                continue
            }
            if firstXcodeBuild.isEmpty { firstXcodeBuild = invocation.xcodeBuildVersion }
            if firstWrapperVersion.isEmpty { firstWrapperVersion = invocation.wrapperVersion }
            // Whole-file reject if wrapper version diverges from what we ship.
            if invocation.wrapperVersion != CasperHMRConfig.pairedWrapperVersion {
                fingerprintDriftDetected = true
                continue
            }
            // Whole-file reject on xcode_build_version drift across entries.
            if !firstXcodeBuild.isEmpty && invocation.xcodeBuildVersion != firstXcodeBuild {
                fingerprintDriftDetected = true
                continue
            }
            // Filter Casper-only files.
            for file in invocation.files where filesUnderCasper(file) {
                byPath[file] = invocation
            }
        }
        if fingerprintDriftDetected {
            cmuxDebugLog("casper.hmr.refused reason=fingerprint_drift xcode_was=\(firstXcodeBuild) wrapper_was=\(firstWrapperVersion)")
            writeOneShotMissEvent(result: "miss_fingerprint", reason: "fingerprint_drift")
            invocationByPath = [:]
            return
        }
        invocationByPath = byPath
    }

    /// Filter: file lives under `<repoRoot>/Sources/Casper/` but NOT under
    /// `<repoRoot>/Sources/Casper/HMR/` (we never hot-reload our own daemon
    /// source).
    private func filesUnderCasper(_ file: CasperHMRCanonicalPath) -> Bool {
        let casperRoot = "\(repoRoot)/Sources/Casper/"
        let hmrRoot = "\(repoRoot)/Sources/Casper/HMR/"
        return file.rawValue.hasPrefix(casperRoot) && !file.rawValue.hasPrefix(hmrRoot)
    }

    // MARK: - AppStorage observation

    private func installDefaultsObserver() {
        defaultsObserverToken = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyDefaultsChange()
            }
        }
    }

    private func readEnabledFromDefaults() {
        // @AppStorage("casper.hmr.enabled") default true.
        if UserDefaults.standard.object(forKey: CasperHMRConfig.userDefaultsEnabledKey) == nil {
            enabled = true
        } else {
            enabled = UserDefaults.standard.bool(forKey: CasperHMRConfig.userDefaultsEnabledKey)
        }
    }

    private func applyDefaultsChange() {
        let wasEnabled = enabled
        readEnabledFromDefaults()
        guard enabled != wasEnabled else { return }
        if enabled {
            loadCommandsJSONL()
            startFSEventsWatcher()
        } else {
            stopFSEventsWatcher()
        }
        cmuxDebugLog("casper.hmr.toggle enabled=\(enabled)")
    }

    // MARK: - FSEvents

    private func startFSEventsWatcher() {
        guard fsEventStream == nil else { return }
        let casperDir = "\(repoRoot)/Sources/Casper" as NSString
        let pathsToWatch = [casperDir] as CFArray
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, info, count, paths, flags, _) in
                guard let info else { return }
                let daemon = Unmanaged<CasperHMRDaemon>.fromOpaque(info).takeUnretainedValue()
                let pathsBuf = unsafeBitCast(paths, to: UnsafeMutablePointer<UnsafePointer<CChar>>.self)
                var fired: [String] = []
                for i in 0..<count {
                    let path = String(cString: pathsBuf[i])
                    let f = flags[i]
                    if (f & UInt32(kFSEventStreamEventFlagItemModified)) != 0 ||
                       (f & UInt32(kFSEventStreamEventFlagItemCreated)) != 0 ||
                       (f & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0 {
                        fired.append(path)
                    }
                }
                guard !fired.isEmpty else { return }
                DispatchQueue.main.async {
                    daemon.handleFSEventsBatch(fired)
                }
            },
            &ctx,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            CFTimeInterval(Double(CasperHMRConfig.debounceMilliseconds) / 1000.0),
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )
        guard let stream else {
            cmuxDebugLog("casper.hmr.fsevents.create_failed")
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        if !FSEventStreamStart(stream) {
            cmuxDebugLog("casper.hmr.fsevents.start_failed")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        fsEventStream = stream
    }

    private func stopFSEventsWatcher() {
        guard let stream = fsEventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        fsEventStream = nil
        for work in pendingCompiles.values { work.cancel() }
        pendingCompiles.removeAll()
    }

    private func handleFSEventsBatch(_ paths: [String]) {
        for path in paths {
            guard path.hasSuffix(".swift") else { continue }
            let canonical = CasperHMRCanonicalPath(path)
            guard shouldProcessSavedFile(canonical) else { continue }
            scheduleCompile(for: canonical)
        }
    }

    /// Apply Req 5's accept/reject filter to a watched-file event.
    func shouldProcessSavedFile(_ canonical: CasperHMRCanonicalPath) -> Bool {
        let path = canonical.rawValue
        // Reject if path is under Sources/Casper/HMR (our own daemon source).
        if path.hasPrefix("\(repoRoot)/Sources/Casper/HMR/") { return false }
        // Reject if path is outside Sources/Casper.
        guard path.hasPrefix("\(repoRoot)/Sources/Casper/") else { return false }
        // Reject build outputs.
        let buildPrefixes = ["/.build/", "/build/", "/DerivedData/", "/.derivedData/"]
        for prefix in buildPrefixes where path.contains(prefix) { return false }
        // Reject hidden directories.
        let components = path.split(separator: "/")
        for comp in components where comp.hasPrefix(".") && comp.count > 1 { return false }
        // Reject sentinel first lines (generated files).
        if firstLineSuggestsGeneratedFile(path: path) { return false }
        return true
    }

    private func firstLineSuggestsGeneratedFile(path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        let firstChunk = (try? fh.read(upToCount: 256)) ?? Data()
        guard let firstChunkStr = String(data: firstChunk, encoding: .utf8) else { return false }
        let firstLine = firstChunkStr.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let lower = firstLine.lowercased()
        let sentinels = [
            "// swiftlint:disable",
            "// generated by",
            "// swift-format-ignore-file",
            "// @generated",
            "// auto-generated",
            "// do not edit",
        ]
        return sentinels.contains { lower.contains($0) }
    }

    // MARK: - Compile pipeline

    private func scheduleCompile(for file: CasperHMRCanonicalPath) {
        if let existing = pendingCompiles[file] {
            existing.cancel()
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Stability check (up to 250 ms of polled stat) and the source-read
            // are both pure file I/O — run them on `compileQueue` so the main
            // actor stays unblocked. The pipeline only hops back to main once
            // the bytes are in hand.
            let started = Date()
            let stable = self.waitForFileStability(filePath: file.rawValue)
            let bytes: Data? = stable
                ? (try? Data(contentsOf: URL(fileURLWithPath: file.rawValue)))
                : nil
            DispatchQueue.main.async {
                self.runCompilePipeline(for: file, started: started, stable: stable, bytes: bytes)
            }
        }
        pendingCompiles[file] = work
        compileQueue.asyncAfter(deadline: .now() + .milliseconds(CasperHMRConfig.debounceMilliseconds), execute: work)
    }

    private func runCompilePipeline(
        for file: CasperHMRCanonicalPath,
        started: Date,
        stable: Bool,
        bytes: Data?
    ) {
        pendingCompiles[file] = nil
        guard let invocation = invocationByPath[file] else {
            writeSwapEvent(.init(
                ts: Date().timeIntervalSince1970,
                path: file.rawValue,
                durationMs: 0,
                result: "miss_argv"
            ))
            cmuxDebugLog("casper.hmr.miss path=\(file.basename)")
            return
        }
        guard stable else {
            writeSwapEvent(.init(
                ts: Date().timeIntervalSince1970,
                path: file.rawValue,
                durationMs: durationMs(started),
                result: "unstable_file"
            ))
            return
        }
        guard let bytes else {
            writeSwapEvent(.init(
                ts: Date().timeIntervalSince1970,
                path: file.rawValue,
                durationMs: durationMs(started),
                result: "miss_argv",
                reason: "unreadable_source"
            ))
            return
        }
        // Source-change classifier (Req 21).
        if CasperHMRConfig.classifierMode == .gate {
            let classifierResult = CasperHMRSourceClassifier.classify(
                beforeBytes: previousBytesForPath(file) ?? bytes,
                afterBytes: bytes
            )
            if classifierResult.kind == .outOfEnvelope {
                writeSwapEvent(.init(
                    ts: Date().timeIntervalSince1970,
                    path: file.rawValue,
                    durationMs: durationMs(started),
                    result: "out_of_envelope_predicted",
                    reason: classifierResult.reason
                ))
                cmuxDebugLog("casper.hmr.swap.out_of_envelope_predicted path=\(file.basename) reason=\(classifierResult.reason ?? "")")
                return
            }
        }
        compileQueue.async { [weak self] in
            self?.executeCompile(file: file, invocation: invocation, bytes: bytes, started: started)
        }
    }

    private nonisolated func executeCompile(
        file: CasperHMRCanonicalPath,
        invocation: CasperHMRSwiftcInvocation,
        bytes: Data,
        started: Date
    ) {
        let stateDir = CasperHMRConfig.stateDirectory()
        let dylibsDir = "\(stateDir)/dylibs"
        let hash = computeHash(
            sourcePath: file.rawValue,
            sourceBytes: bytes,
            compileArgv: invocation.hashCompileArgv(savedFile: file.rawValue),
            linkArgv: invocation.hashLinkArgv()
        )
        let objectPath = "\(dylibsDir)/\(hash).o"
        let dylibPath = "\(dylibsDir)/\(hash).dylib"

        // Short-circuit: hash matches previous AND dylib exists on disk.
        Task { @MainActor in
            if let prev = self.previousHashByPath[file], prev == hash,
               FileManager.default.fileExists(atPath: dylibPath) {
                self.previousHashByPath[file] = hash
                self.writeSwapEvent(.init(
                    ts: Date().timeIntervalSince1970,
                    path: file.rawValue,
                    durationMs: self.durationMs(started),
                    result: "unchanged"
                ))
                return
            }
            self.continueCompileAfterHash(
                file: file,
                invocation: invocation,
                hash: hash,
                objectPath: objectPath,
                dylibPath: dylibPath,
                started: started
            )
        }
    }

    @MainActor
    private func continueCompileAfterHash(
        file: CasperHMRCanonicalPath,
        invocation: CasperHMRSwiftcInvocation,
        hash: String,
        objectPath: String,
        dylibPath: String,
        started: Date
    ) {
        compileQueue.async { [weak self] in
            self?.runSubprocessChain(
                file: file,
                invocation: invocation,
                hash: hash,
                objectPath: objectPath,
                dylibPath: dylibPath,
                started: started
            )
        }
    }

    private nonisolated func postSubprocessFailure(
        file: CasperHMRCanonicalPath,
        started: Date,
        result: SubprocessResult,
        timeoutLabel: String,
        failLabel: String
    ) {
        let resultLabel = result.timedOut ? timeoutLabel : failLabel
        let stderrTail = result.stderrTail
        Task { @MainActor in
            self.writeSwapEvent(.init(
                ts: Date().timeIntervalSince1970,
                path: file.rawValue,
                durationMs: self.durationMs(started),
                result: resultLabel,
                stderrTail: stderrTail
            ))
        }
    }

    private nonisolated func runSubprocessChain(
        file: CasperHMRCanonicalPath,
        invocation: CasperHMRSwiftcInvocation,
        hash: String,
        objectPath: String,
        dylibPath: String,
        started: Date
    ) {
        // Compile via swift -frontend -c (single-primary-file mode). The
        // driver no longer accepts `-primary-file` for our shape on Xcode 26.5
        // — see compileArgv() for the rationale.
        let compileArgv = ["-frontend"] + invocation.compileArgv(savedFile: file.rawValue, objectPath: objectPath)
        let realSwiftc = resolveRealSwiftc(envSubset: invocation.envSubset)
        let realSwift = resolveRealSwift(envSubset: invocation.envSubset, swiftcPath: realSwiftc)
        let compileResult = runSubprocess(
            executable: realSwift,
            arguments: compileArgv,
            envSubset: invocation.envSubset,
            workingDirectory: invocation.workingDirectory
        )
        if compileResult.exitCode != 0 {
            postSubprocessFailure(file: file, started: started, result: compileResult, timeoutLabel: "timeout", failLabel: "compile_fail")
            return
        }

        // Link.
        let linkArgv = invocation.linkArgv(objectPath: objectPath, dylibPath: dylibPath)
        let linkResult = runSubprocess(
            executable: realSwiftc,
            arguments: linkArgv,
            envSubset: invocation.envSubset,
            workingDirectory: invocation.workingDirectory
        )
        if linkResult.exitCode != 0 {
            postSubprocessFailure(file: file, started: started, result: linkResult, timeoutLabel: "timeout", failLabel: "link_fail")
            return
        }

        // Clear quarantine attr if present (silent).
        _ = runSubprocess(
            executable: "/usr/bin/xattr",
            arguments: ["-d", "com.apple.quarantine", dylibPath],
            envSubset: [:],
            workingDirectory: nil
        )

        // Ad-hoc codesign. Phase 0 picks whether --options=runtime is needed;
        // PR 1 ships without it (simpler variant). If a dlopen failure pattern
        // surfaces in dogfood, flip via a CasperHMRConfig constant.
        let signResult = runSubprocess(
            executable: "/usr/bin/codesign",
            arguments: ["--sign", "-", "--timestamp=none", "--identifier", "casper-hmr-\(hash)", dylibPath],
            envSubset: [:],
            workingDirectory: nil
        )
        if signResult.exitCode != 0 {
            postSubprocessFailure(file: file, started: started, result: signResult, timeoutLabel: "timeout", failLabel: "sign_fail")
            return
        }

        // Pre-dlopen breadcrumb (Req 10 Behavior step 10).
        writePendingBreadcrumb(path: file.rawValue, hash: hash)

        // dlopen.
        guard let handle = dlopen(dylibPath, RTLD_NOW | RTLD_GLOBAL) else {
            let dlerr = String(cString: dlerror())
            Task { @MainActor in
                self.writeSwapEvent(.init(
                    ts: Date().timeIntervalSince1970,
                    path: file.rawValue,
                    durationMs: self.durationMs(started),
                    result: "dlopen_fail",
                    stderrTail: dlerr
                ))
            }
            return
        }

        // Patch the new dylib's Swift field-offset (`Wvd`) values from HOST
        // before any swapped code runs. The Swift runtime only realises class
        // metadata (and the field-offset adjustment for ObjC superclasses)
        // once per class; since the class is already registered when NEW is
        // dlopen'd, NEW's __DATA copy of Wvd stays at compile-time
        // placeholders. Without this step a swapped method body writes
        // through the wrong instance offset and corrupts ObjC ivars.
        let stateDirPrefix = "\(CasperHMRConfig.stateDirectory())/dylibs"
        let foPatch = CasperHMRFieldOffsetPatcher.patchFromHost(
            dylibPath: dylibPath,
            stateDirPrefix: stateDirPrefix
        )

        // Pure-Swift dylibs don't emit __DATA[_CONST],__interpose sections,
        // so the dyld static-interpose path is a dead end for our compile
        // pipeline. Use fishhook to rewrite GOT/__la_symbol_ptr entries in
        // every loaded image instead (CasperHMRInterposer). See that file's
        // header comment for the lifecycle constraints.
        let symbolSet = symbolSetForObject(objectPath: objectPath)
        let walkResult = CasperHMRInterposer.rebindAllImages(
            dylibHandle: handle,
            dylibPath: dylibPath,
            stateDirPrefix: stateDirPrefix,
            symbolSet: symbolSet.isEmpty ? nil : symbolSet
        )
        // dyld retains the loaded image's mapping independently of our handle,
        // and we deliberately never `dlclose` (already-rebound call sites would
        // jump into unmapped memory), so we don't keep the handle around.
        _ = handle
        Task { @MainActor in
            self.previousHashByPath[file] = hash
            let event = CasperHMRSwapEvent(
                ts: Date().timeIntervalSince1970,
                path: file.rawValue,
                durationMs: self.durationMs(started),
                result: walkResult.result,
                interposeEntries: walkResult.entryCount,
                matchedSymbols: walkResult.matchedSymbols,
                reason: walkResult.reason,
                fieldOffsetPatched: foPatch.patched,
                fieldOffsetUnchanged: foPatch.unchanged,
                fieldOffsetMissing: foPatch.missing
            )
            self.writeSwapEvent(event)
            if event.result == "ok" || event.result == "ok_unverified" {
                let userInfo: [String: Any] = [
                    "path": file.rawValue,
                    "result": event.result,
                    "matched_symbols": walkResult.matchedSymbols,
                ]
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .casperHMRReloaded, object: nil, userInfo: userInfo)
                }
            }
            self.recordLatency(event)
            self.evictDylibsIfOverBound()
        }
    }

    // MARK: - File stability

    /// Pure file I/O; runs on `compileQueue`, never on the main actor. Returns
    /// true once two back-to-back stat calls agree on size+mtime and the
    /// file reads end-to-end (proxy for "the editor's atomic-replace write
    /// has settled").
    nonisolated func waitForFileStability(filePath: String) -> Bool {
        let intervalNs = UInt64(CasperHMRConfig.fileStabilityIntervalMilliseconds) * 1_000_000
        for _ in 0..<CasperHMRConfig.fileStabilityMaxCycles {
            var st1 = stat()
            guard stat(filePath, &st1) == 0 else { return false }
            let size1 = st1.st_size
            let mtime1 = st1.st_mtimespec
            usleep(useconds_t(intervalNs / 1000))
            var st2 = stat()
            guard stat(filePath, &st2) == 0 else { return false }
            let size2 = st2.st_size
            let mtime2 = st2.st_mtimespec
            if size1 == size2 && mtime1.tv_sec == mtime2.tv_sec && mtime1.tv_nsec == mtime2.tv_nsec {
                if (try? Data(contentsOf: URL(fileURLWithPath: filePath))) != nil {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Hash

    private nonisolated func computeHash(
        sourcePath: String,
        sourceBytes: Data,
        compileArgv: [String],
        linkArgv: [String]
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(sourcePath.utf8))
        hasher.update(data: Data([0x1f]))
        hasher.update(data: sourceBytes)
        hasher.update(data: Data([0x1f]))
        hasher.update(data: Data(compileArgv.joined(separator: "\u{1f}").utf8))
        hasher.update(data: Data([0x1f]))
        hasher.update(data: Data(linkArgv.joined(separator: "\u{1f}").utf8))
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    // MARK: - Subprocess

    private nonisolated func runSubprocess(
        executable: String,
        arguments: [String],
        envSubset: [String: String],
        workingDirectory: String?
    ) -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        var env = envSubset
        // Inject DEVELOPER_DIR/SDKROOT/HOME if missing.
        let parentEnv = ProcessInfo.processInfo.environment
        for key in ["DEVELOPER_DIR", "SDKROOT", "PATH", "HOME"] {
            if env[key] == nil, let v = parentEnv[key] { env[key] = v }
        }
        // Ensure SWIFT_EXEC is NOT in env (don't recurse through wrapper).
        env.removeValue(forKey: "SWIFT_EXEC")
        process.environment = env
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return SubprocessResult(exitCode: 127, timedOut: false, stderrTail: "spawn_fail: \(error.localizedDescription)")
        }
        let deadline = DispatchTime.now() + .seconds(Int(CasperHMRConfig.subprocessTimeoutSeconds))
        let queue = DispatchQueue.global(qos: .userInitiated)
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            process.waitUntilExit()
            semaphore.signal()
        }
        let timedOut = semaphore.wait(timeout: deadline) == .timedOut
        if timedOut {
            process.terminate()
            return SubprocessResult(exitCode: 124, timedOut: true, stderrTail: "subprocess_timeout")
        }
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let tail = String(stderr.suffix(4096))
        return SubprocessResult(exitCode: process.terminationStatus, timedOut: false, stderrTail: tail)
    }

    private nonisolated func resolveRealSwiftc(envSubset: [String: String]) -> String {
        // Honor DEVELOPER_DIR-cached resolution if available.
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        let developerDir = envSubset["DEVELOPER_DIR"] ?? env["DEVELOPER_DIR"] ?? "default"
        let cachePath = "\(home)/.casper/hmr/tools/cache/real-swiftc-\(developerDir.replacingOccurrences(of: "/", with: "_"))"
        if let cached = try? String(contentsOfFile: cachePath, encoding: .utf8) {
            let trimmed = cached.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) {
                return trimmed
            }
        }
        // Fall back to xcrun lookup.
        let xcrun = Process()
        xcrun.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        xcrun.arguments = ["--find", "swiftc"]
        let pipe = Pipe()
        xcrun.standardOutput = pipe
        xcrun.standardError = Pipe()
        do {
            try xcrun.run()
            xcrun.waitUntilExit()
        } catch {
            return "/usr/bin/swiftc"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? "/usr/bin/swiftc" : path
    }

    /// Resolve `swift` (frontend entrypoint) sibling to the resolved
    /// `swiftc`. Both are symlinks to `swift-frontend` in the Xcode toolchain;
    /// the daemon needs the `swift` name because it invokes `swift -frontend`
    /// for the single-file compile (see `compileArgv()` rationale).
    private nonisolated func resolveRealSwift(envSubset: [String: String], swiftcPath: String) -> String {
        let sibling = (swiftcPath as NSString)
            .deletingLastPathComponent
            .appending("/swift")
        if FileManager.default.isExecutableFile(atPath: sibling) {
            return sibling
        }
        // Fall back to xcrun --find.
        let xcrun = Process()
        xcrun.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        xcrun.arguments = ["--find", "swift"]
        let pipe = Pipe()
        xcrun.standardOutput = pipe
        xcrun.standardError = Pipe()
        do {
            try xcrun.run()
            xcrun.waitUntilExit()
        } catch {
            return "/usr/bin/swift"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? "/usr/bin/swift" : path
    }

    // MARK: - Symbol-set extraction

    /// Read every external symbol defined in the just-compiled `.o` so the
    /// interposer knows which call sites to rebind. Scanning only this one
    /// object (vs every `.o` in the dylibs dir) keeps the per-swap budget to a
    /// single `nm` invocation.
    private nonisolated func symbolSetForObject(objectPath: String) -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        process.arguments = ["-gU", objectPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let str = String(data: data, encoding: .utf8) else { return [] }
        var symbols: Set<String> = []
        for line in str.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard let sym = parts.last else { continue }
            symbols.insert(String(sym))
        }
        return symbols
    }

    // MARK: - Events

    private struct SubprocessResult {
        let exitCode: Int32
        let timedOut: Bool
        let stderrTail: String
    }

    @MainActor
    private func writeSwapEvent(_ event: CasperHMRSwapEvent) {
        appendEventsJSONL(event)
        cmuxDebugLog("casper.hmr.swap.\(event.result) path=\((event.path as NSString).lastPathComponent) duration_ms=\(event.durationMs) interpose=\(event.interposeEntries) matched=\(event.matchedSymbols.count) fo_patched=\(event.fieldOffsetPatched) fo_missing=\(event.fieldOffsetMissing)")
        CasperHMRDebugWindow.shared.recordEvent(event)
    }

    private nonisolated func writePendingBreadcrumb(path: String, hash: String) {
        let event = CasperHMRSwapEvent(
            ts: Date().timeIntervalSince1970,
            path: path,
            durationMs: 0,
            result: "dlopen_pending",
            interposeEntries: 0,
            matchedSymbols: [],
            reason: nil,
            stderrTail: nil,
            hash: hash
        )
        appendEventsJSONLNonisolated(event)
        fsyncEventsFile()
    }

    private nonisolated func appendEventsJSONLNonisolated(_ event: CasperHMRSwapEvent) {
        let stateDir = CasperHMRConfig.stateDirectory()
        let path = "\(stateDir)/events.jsonl"
        let lockPath = "\(stateDir)/events.jsonl.lock"
        let lockFd = open(lockPath, O_CREAT | O_WRONLY, 0o600)
        guard lockFd >= 0 else { return }
        defer { close(lockFd) }
        guard flock(lockFd, LOCK_EX) == 0 else { return }
        defer { _ = flock(lockFd, LOCK_UN) }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let line = event.toJSONLine() + "\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
    }

    @MainActor
    private func appendEventsJSONL(_ event: CasperHMRSwapEvent) {
        appendEventsJSONLNonisolated(event)
    }

    private nonisolated func fsyncEventsFile() {
        let path = "\(CasperHMRConfig.stateDirectory())/events.jsonl"
        let fd = open(path, O_WRONLY)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }

    @MainActor
    private func writeOneShotMissEvent(result: String, reason: String) {
        let event = CasperHMRSwapEvent(
            ts: Date().timeIntervalSince1970,
            path: "",
            durationMs: 0,
            result: result,
            reason: reason
        )
        appendEventsJSONL(event)
    }

    @MainActor
    private func recordLatency(_ event: CasperHMRSwapEvent) {
        guard event.result != "unchanged" else { return }
        latencyWindow.append(Double(event.durationMs))
        if latencyWindow.count > CasperHMRConfig.latencyWindowSize {
            latencyWindow.removeFirst(latencyWindow.count - CasperHMRConfig.latencyWindowSize)
        }
    }

    @MainActor
    func currentP50P95() -> (p50: Int, p95: Int) {
        guard !latencyWindow.isEmpty else { return (0, 0) }
        let sorted = latencyWindow.sorted()
        let p50Index = Int(Double(sorted.count) * 0.5)
        let p95Index = Int(Double(sorted.count) * 0.95)
        return (
            Int(sorted[min(p50Index, sorted.count - 1)]),
            Int(sorted[min(p95Index, sorted.count - 1)])
        )
    }

    @MainActor
    private func evictDylibsIfOverBound() {
        let dir = "\(CasperHMRConfig.stateDirectory())/dylibs"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        let dylibs = entries.filter { $0.hasSuffix(".dylib") }
        guard dylibs.count > CasperHMRConfig.dylibDirMaxFiles else {
            // Also check bytes.
            var totalBytes: Int64 = 0
            for d in dylibs {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: "\(dir)/\(d)"),
                   let size = attrs[.size] as? Int64 {
                    totalBytes += size
                }
            }
            guard totalBytes > CasperHMRConfig.dylibDirMaxBytes else { return }
            evictOldestDylibs(dir: dir, dylibs: dylibs)
            return
        }
        evictOldestDylibs(dir: dir, dylibs: dylibs)
    }

    @MainActor
    private func evictOldestDylibs(dir: String, dylibs: [String]) {
        let entries = dylibs.compactMap { name -> (String, Date)? in
            let path = "\(dir)/\(name)"
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            return (path, mtime)
        }
        let sorted = entries.sorted { $0.1 < $1.1 }
        // Evict oldest 25% to give breathing room.
        let toEvict = max(1, sorted.count / 4)
        for (path, _) in sorted.prefix(toEvict) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Helpers

    private nonisolated func durationMs(_ started: Date) -> Int {
        return Int(Date().timeIntervalSince(started) * 1000)
    }

    /// Read previous bytes for classifier — uses the previously-swapped source
    /// for delta classification. Not persisted across daemon launches, so the
    /// first save after launch always classifies against the current bytes
    /// (which then classifies as bodyLikely).
    @MainActor
    private func previousBytesForPath(_ file: CasperHMRCanonicalPath) -> Data? {
        // PR 1: no persistence; classifier always runs against current bytes.
        return nil
    }
}

/// Swap event record (Req 10). Serialized into events.jsonl and surfaced in
/// the Recent Swaps debug panel.
struct CasperHMRSwapEvent {
    let ts: TimeInterval
    let path: String
    let durationMs: Int
    let result: String
    var interposeEntries: Int = 0
    var matchedSymbols: [String] = []
    var reason: String? = nil
    var stderrTail: String? = nil
    var hash: String? = nil
    var fieldOffsetPatched: Int = 0
    var fieldOffsetUnchanged: Int = 0
    var fieldOffsetMissing: Int = 0

    func toJSONLine() -> String {
        var parts: [String] = []
        parts.append("\"ts\":\(String(format: "%.6f", ts))")
        parts.append("\"path\":\(jsonString(path))")
        parts.append("\"duration_ms\":\(durationMs)")
        parts.append("\"result\":\(jsonString(result))")
        parts.append("\"interpose_entries\":\(interposeEntries)")
        let syms = matchedSymbols.map { "\"\(escapeJSON($0))\"" }.joined(separator: ",")
        parts.append("\"matched_symbols\":[\(syms)]")
        parts.append("\"fo_patched\":\(fieldOffsetPatched)")
        parts.append("\"fo_unchanged\":\(fieldOffsetUnchanged)")
        parts.append("\"fo_missing\":\(fieldOffsetMissing)")
        if let reason {
            parts.append("\"reason\":\(jsonString(reason))")
        }
        if let stderrTail {
            parts.append("\"stderr_tail\":\(jsonString(stderrTail))")
        }
        if let hash {
            parts.append("\"hash\":\(jsonString(hash))")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }
}

private func jsonString(_ s: String) -> String {
    return "\"\(escapeJSON(s))\""
}

private func escapeJSON(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count + 2)
    for c in s {
        switch c {
        case "\\": out.append("\\\\")
        case "\"": out.append("\\\"")
        case "\n": out.append("\\n")
        case "\r": out.append("\\r")
        case "\t": out.append("\\t")
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

/// Entry point invoked from cmuxApp.init() in DEBUG builds. Release builds
/// dead-strip this whole file along with the daemon.
@MainActor
func casperHMRBootstrap() {
    CasperHMRDaemon.shared.boot()
}

#else
@inlinable
func casperHMRBootstrap() {}
#endif
