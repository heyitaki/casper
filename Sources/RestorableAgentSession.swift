import Foundation
import CMUXAgentLaunch

fileprivate func shellSingleQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

enum AgentResumeCommandBuilder {
    private static let claudeAuthSelectionEnvironmentKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CONFIG_DIR"
    ]
    static func resumeShellCommand(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        registrationOverride: CmuxVaultAgentRegistration? = nil,
        includeWorkingDirectoryPrefix: Bool = true
    ) -> String? {
        let customRegistration = registrationOverride
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let argv = resumeArguments(
                  kind: kind,
                  sessionId: sessionId,
                  launchCommand: launchCommand,
                  workingDirectory: workingDirectory,
                  customRegistration: customRegistration
              ),
              !argv.isEmpty else {
            return nil
        }
        return assembleShellCommand(
            kind: kind,
            argv: argv,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: customRegistration,
            includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix
        )
    }

    // CASPER: Fork support for the sidebar "Fork Session" action. Builds the
    // shell command that branches a prior agent session into a *new* session,
    // leaving the original untouched. Only claude + codex are forkable today —
    // claude forks via the `--fork-session` flag on resume, codex via its own
    // `fork` subcommand. Reuses the resume machinery (env/cwd/launcher/arg
    // preservation) so auth selection and the claudeTeams launcher survive.
    // Delete if upstream adds first-class session forking.
    static func forkShellCommand(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        includeWorkingDirectoryPrefix: Bool = true
    ) -> String? {
        guard !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let argv = forkArguments(
                  kind: kind,
                  sessionId: sessionId,
                  launchCommand: launchCommand
              ),
              !argv.isEmpty else {
            return nil
        }
        return assembleShellCommand(
            kind: kind,
            argv: argv,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: nil,
            includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix
        )
    }

    // CASPER: per-kind fork argv. nil for any non-forkable kind. Delete with
    // `forkShellCommand` if upstream adds first-class session forking.
    private static func forkArguments(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> [String]? {
        switch kind {
        case .claude:
            // claude --resume <id> [preserved] --fork-session. Reuses the
            // resume argv so the claudeTeams launcher path is honored.
            guard let resume = resumeArguments(
                kind: .claude,
                sessionId: sessionId,
                launchCommand: launchCommand,
                workingDirectory: nil,
                customRegistration: nil
            ) else {
                return nil
            }
            return resume + ["--fork-session"]
        case .codex:
            // codex fork [preserved] <id> — same argv as resume with the
            // subcommand swapped (see codexSessionArguments).
            return codexSessionArguments(
                subcommand: "fork",
                sessionId: sessionId,
                launchCommand: launchCommand
            )
        default:
            return nil
        }
    }

    // CASPER: codex's resume and fork argv differ only by the subcommand
    // token, so build both here to keep them in lockstep. The launch sanitizer
    // peels a leading `resume <id>` but hard-blocks a leading `fork` (it's in
    // codexPolicy.nonRestorableCommands), so strip a leading `fork <id>`
    // ourselves first — otherwise a session whose own launch was `codex fork …`
    // (e.g. produced by this very feature) could be neither resumed nor forked.
    // Delete the `fork` handling if upstream teaches the sanitizer to treat
    // `fork` like `resume`.
    private static func codexSessionArguments(
        subcommand: String,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?
    ) -> [String]? {
        let metadata = agentMetadata(kind: .codex, registration: nil)
        let original = commandParts(
            launchCommand: launchCommand,
            fallbackExecutable: metadata.executable
        )
        var tail = original.tail
        if tail.first == "fork" {
            tail.removeFirst()
            if let next = tail.first, !next.hasPrefix("-") {
                tail.removeFirst()
            }
        }
        guard let sanitizerKey = metadata.sanitizerKey,
              let preserved = AgentLaunchSanitizer.preservedArguments(
                  kind: sanitizerKey,
                  args: tail
              ) else {
            return nil
        }
        return [original.executable, subcommand] + preserved + [sessionId]
    }

    /// Builds the shell command for *starting a fresh agent* (no resume). Used
    /// as a fallback when the recorded session is orphaned (e.g. Claude's
    /// transcript file is missing). Preserves cwd + environment from the
    /// original launch so the new process inherits auth selection etc.
    static func freshLaunchShellCommand(
        kind: RestorableAgentKind,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        registrationOverride: CmuxVaultAgentRegistration? = nil,
        includeWorkingDirectoryPrefix: Bool = true
    ) -> String? {
        let metadata = agentMetadata(kind: kind, registration: registrationOverride)
        let original = commandParts(
            launchCommand: launchCommand,
            fallbackExecutable: metadata.executable
        )
        let preservedTail: [String]
        if let sanitizerKey = metadata.sanitizerKey {
            guard let preserved = AgentLaunchSanitizer.preservedArguments(
                kind: sanitizerKey,
                args: original.tail
            ) else {
                return nil
            }
            preservedTail = preserved
        } else {
            preservedTail = original.tail
        }
        return assembleShellCommand(
            kind: kind,
            argv: [original.executable] + preservedTail,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registrationOverride,
            includeWorkingDirectoryPrefix: includeWorkingDirectoryPrefix
        )
    }

    /// Shared tail of `resumeShellCommand` / `freshLaunchShellCommand`: prepend
    /// preserved env vars as an `env …` prefix, quote everything, and add a
    /// `cd <cwd> &&` prefix when one was requested.
    private static func assembleShellCommand(
        kind: RestorableAgentKind,
        argv: [String],
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        registrationOverride: CmuxVaultAgentRegistration?,
        includeWorkingDirectoryPrefix: Bool
    ) -> String {
        var commandParts: [String] = []
        let environmentParts = launchEnvironmentParts(kind: kind, environment: launchCommand?.environment)
        if !environmentParts.isEmpty {
            commandParts.append("env")
            commandParts.append(contentsOf: environmentParts)
        }
        commandParts.append(contentsOf: argv)
        var shellCommand = commandParts.map(shellSingleQuoted).joined(separator: " ")
        let cwd = !includeWorkingDirectoryPrefix || registrationOverride?.cwd == .ignore
            ? nil
            : normalized(workingDirectory ?? launchCommand?.workingDirectory)
        if let cwd {
            shellCommand = "cd \(shellSingleQuoted(cwd)) && \(shellCommand)"
        }
        return shellCommand
    }

    /// Per-kind dispatch: default executable name for `commandParts` fallback,
    /// and the `AgentLaunchSanitizer` key used to whitelist arguments. Kept in
    /// one place so `freshLaunchShellCommand` and `resumeArguments` can't drift
    /// out of sync. `sanitizerKey == nil` means "preserve all original args".
    private static func agentMetadata(
        kind: RestorableAgentKind,
        registration: CmuxVaultAgentRegistration?
    ) -> (executable: String, sanitizerKey: String?) {
        if case .custom = kind, let registration {
            return (registration.defaultExecutable, nil)
        }
        switch kind {
        case .claude: return ("claude", "claude")
        case .codex: return ("codex", "codex")
        case .pi: return ("pi", "pi")
        case .cursor: return ("cursor-agent", "cursor")
        case .gemini: return ("gemini", "gemini")
        case .opencode: return ("opencode", "opencode")
        case .rovodev: return ("acli", "rovodev")
        case .hermesAgent: return ("hermes", "hermes-agent")
        case .copilot: return ("copilot", "copilot")
        case .codebuddy: return ("codebuddy", "codebuddy")
        case .factory: return ("droid", "factory")
        case .qoder: return ("qodercli", "qoder")
        case .custom: return ("cmux", nil)
        }
    }

    private static func launchEnvironmentParts(
        kind: RestorableAgentKind,
        environment: [String: String]?
    ) -> [String] {
        guard let environment, !environment.isEmpty else {
            return []
        }

        var environmentParts: [String] = []
        var preservedClaudeAuthSelectionEnvironmentKeys: [String] = []
        let selectedEnvironment = AgentLaunchEnvironmentPolicy.selectedEnvironment(from: environment)
        for key in selectedEnvironment.keys.sorted() {
            guard let value = selectedEnvironment[key] else { continue }
            environmentParts.append("\(key)=\(value)")
            if kind == .claude,
               claudeAuthSelectionEnvironmentKeys.contains(key) {
                preservedClaudeAuthSelectionEnvironmentKeys.append(key)
            }
        }
        if !preservedClaudeAuthSelectionEnvironmentKeys.isEmpty {
            environmentParts.append("CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV=1")
            environmentParts.append(
                "CMUX_PRESERVE_CLAUDE_AUTH_SELECTION_ENV_KEYS=\(preservedClaudeAuthSelectionEnvironmentKeys.joined(separator: ","))"
            )
        }
        return environmentParts
    }

    private static func resumeArguments(
        kind: RestorableAgentKind,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?,
        customRegistration: CmuxVaultAgentRegistration?
    ) -> [String]? {
        switch launchCommand?.launcher {
        case "claudeTeams":
            let original = commandParts(
                launchCommand: launchCommand,
                fallbackExecutable: "cmux"
            )
            var args = original.tail
            if args.first == "claude-teams" {
                args.removeFirst()
            }
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "claude", args: args) else { return nil }
            return [original.executable, "claude-teams", "--resume", sessionId] + preserved
        case "omo":
            let original = commandParts(
                launchCommand: launchCommand,
                fallbackExecutable: "cmux"
            )
            var args = original.tail
            if args.first == "omo" {
                args.removeFirst()
            }
            guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: "opencode", args: args) else { return nil }
            return [original.executable, "omo", "--session", sessionId] + preserved
        case "omx", "omc":
            return nil
        default:
            break
        }

        if case .custom = kind {
            guard let customRegistration else { return nil }
            let arguments = customResumeArguments(
                registration: customRegistration,
                sessionId: sessionId,
                launchCommand: launchCommand,
                workingDirectory: workingDirectory
            )
            return arguments.isEmpty ? nil : arguments
        }

        let metadata = agentMetadata(kind: kind, registration: customRegistration)
        switch kind {
        case .claude, .cursor, .gemini, .copilot, .codebuddy, .factory, .qoder:
            return resumeWithOption(
                kind: metadata.sanitizerKey ?? "",
                launchCommand: launchCommand,
                fallbackExecutable: metadata.executable,
                option: "--resume",
                sessionId: sessionId
            )
        case .pi:
            return resumeWithOption(
                kind: metadata.sanitizerKey ?? "",
                launchCommand: launchCommand,
                fallbackExecutable: metadata.executable,
                option: "--session",
                sessionId: sessionId
            )
        case .codex:
            // CASPER: routed through the shared codex argv builder so resume
            // and fork stay in sync and a `codex fork …`-launched session
            // remains resumable. Revert to the inline form if forkArguments is
            // removed.
            return codexSessionArguments(
                subcommand: "resume",
                sessionId: sessionId,
                launchCommand: launchCommand
            )
        case .opencode:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: metadata.executable)
            guard let sanitizerKey = metadata.sanitizerKey,
                  let preserved = AgentLaunchSanitizer.preservedArguments(kind: sanitizerKey, args: original.tail)
            else { return nil }
            return [original.executable, "--session", sessionId] + preserved
        case .rovodev:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: metadata.executable)
            guard let sanitizerKey = metadata.sanitizerKey,
                  let preserved = AgentLaunchSanitizer.preservedArguments(kind: sanitizerKey, args: original.tail)
            else { return nil }
            return [original.executable, "rovodev", "run", "--restore", sessionId] + preserved
        case .hermesAgent:
            let original = commandParts(launchCommand: launchCommand, fallbackExecutable: metadata.executable)
            guard let sanitizerKey = metadata.sanitizerKey,
                  let preserved = AgentLaunchSanitizer.preservedArguments(kind: sanitizerKey, args: original.tail)
            else { return nil }
            return [original.executable] + preserved + ["--resume", sessionId]
        case .custom:
            return nil
        }
    }

    private static func customResumeArguments(
        registration: CmuxVaultAgentRegistration,
        sessionId: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        workingDirectory: String?
    ) -> [String] {
        let templateParts = splitShellWords(registration.resumeCommand)
        guard !templateParts.isEmpty else { return [] }
        let original = commandParts(
            launchCommand: launchCommand,
            fallbackExecutable: registration.defaultExecutable
        )
        let sessionDirectory = normalized(registration.sessionDirectory).map {
            ($0 as NSString).expandingTildeInPath
        }
        let replacements: [String: String] = [
            "sessionId": sessionId,
            "sessionPath": sessionId,
            "executable": original.executable,
            "cwd": normalized(workingDirectory ?? launchCommand?.workingDirectory) ?? "",
            "sessionDir": sessionDirectory ?? "",
        ]
        var resolved: [String] = []
        for part in templateParts {
            guard let value = resolveTemplatePart(part, replacements: replacements) else { return [] }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            resolved.append(trimmed)
        }
        return resolved
    }

    private static func resolveTemplatePart(
        _ part: String,
        replacements: [String: String]
    ) -> String? {
        var resolved = ""
        var searchStart = part.startIndex
        while let opening = part[searchStart...].range(of: "{{") {
            resolved.append(contentsOf: part[searchStart..<opening.lowerBound])
            guard let closing = part[opening.upperBound...].range(of: "}}") else {
                resolved.append(contentsOf: part[opening.lowerBound...])
                return resolved
            }
            let key = String(part[opening.upperBound..<closing.lowerBound])
            if let replacement = replacements[key] {
                if replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return nil
                }
                resolved += replacement
            } else {
                resolved.append(contentsOf: part[opening.lowerBound..<closing.upperBound])
            }
            searchStart = closing.upperBound
        }
        resolved.append(contentsOf: part[searchStart...])
        return resolved
    }

    private static func splitShellWords(_ command: String) -> [String] {
        enum Quote {
            case single
            case double
        }

        var words: [String] = []
        var current = ""
        var quote: Quote?
        var escaping = false

        func finishWord() {
            guard !current.isEmpty else { return }
            words.append(current)
            current = ""
        }

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            switch (quote, character) {
            case (.single, "'"), (.double, "\""):
                quote = nil
            case (nil, "'"):
                quote = .single
            case (nil, "\""):
                quote = .double
            case (nil, " "), (nil, "\t"), (nil, "\n"):
                finishWord()
            default:
                current.append(character)
            }
        }
        if escaping {
            current.append("\\")
        }
        finishWord()
        return words
    }

    private static func resumeWithOption(
        kind: String,
        launchCommand: AgentLaunchCommandSnapshot?,
        fallbackExecutable: String,
        option: String,
        sessionId: String
    ) -> [String]? {
        let original = commandParts(launchCommand: launchCommand, fallbackExecutable: fallbackExecutable)
        guard let preserved = AgentLaunchSanitizer.preservedArguments(kind: kind, args: original.tail) else {
            return nil
        }
        return [original.executable, option, sessionId] + preserved
    }

    private static func commandParts(
        launchCommand: AgentLaunchCommandSnapshot?,
        fallbackExecutable: String
    ) -> (executable: String, tail: [String]) {
        let arguments = launchCommand?.arguments ?? []
        let executable = normalized(launchCommand?.executablePath)
            ?? arguments.first
            ?? fallbackExecutable
        let tail = arguments.isEmpty ? [] : Array(arguments.dropFirst())
        return (executable, tail)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

struct SessionRestorableAgentSnapshot: Codable, Sendable {
    static let maxInlineStartupInputBytes = 900

    var kind: RestorableAgentKind
    var sessionId: String
    var workingDirectory: String?
    var launchCommand: AgentLaunchCommandSnapshot?
    var registration: CmuxVaultAgentRegistration? = nil

    var resumeCommand: String? {
        AgentResumeCommandBuilder.resumeShellCommand(
            kind: kind,
            sessionId: sessionId,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registration
        )
    }

    /// Returns the shell input to run on terminal start for this restored agent.
    /// When `homeDirectory` is supplied, Claude orphan detection is enabled:
    /// a recorded session with no transcript on disk falls back to a fresh
    /// launch with a console notice. Pass `nil` (the default) to skip the
    /// disk check — tests that don't seed transcripts opt out this way.
    func resumeStartupInput(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        homeDirectory: String? = nil
    ) -> String? {
        guard let command = resumeCommand else { return nil }

        // SessionStart fires before Claude persists any messages, so a process
        // killed before its first prompt leaves a hook record with no
        // ~/.claude/projects/<slug>/<sessionId>.jsonl. Resuming that orphan
        // makes Claude exit immediately with "No conversation found". When we
        // can detect that, fall back to spawning a fresh session (with the
        // captured launch settings) and print a notice so the user knows why.
        if let homeDirectory,
           kind == .claude,
           !RestorableAgentSessionIndex.claudeTranscriptExists(
               sessionId: sessionId,
               workingDirectory: workingDirectory,
               homeDirectory: homeDirectory,
               fileManager: fileManager
           ) {
            return freshLaunchStartupInput(
                fileManager: fileManager,
                temporaryDirectory: temporaryDirectory
            )
        }

        return materializeStartupInput(
            command: command,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        )
    }

    private func materializeStartupInput(
        command: String,
        fileManager: FileManager,
        temporaryDirectory: URL
    ) -> String? {
        let inlineInput = command + "\n"
        guard inlineInput.utf8.count > Self.maxInlineStartupInputBytes else {
            return inlineInput
        }
        guard let scriptURL = AgentResumeScriptStore.writeLauncherScript(
            command: command,
            kind: kind,
            sessionId: sessionId,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        ) else {
            return nil
        }

        let scriptInput = "/bin/zsh \(shellSingleQuoted(scriptURL.path))\n"
        return scriptInput.utf8.count <= Self.maxInlineStartupInputBytes ? scriptInput : nil
    }

    private func freshLaunchStartupInput(
        fileManager: FileManager,
        temporaryDirectory: URL
    ) -> String? {
        guard let launchPart = AgentResumeCommandBuilder.freshLaunchShellCommand(
            kind: kind,
            launchCommand: launchCommand,
            workingDirectory: workingDirectory,
            registrationOverride: registration
        ) else {
            return nil
        }
        let noticeBody = "cmux: previous Claude session \(sessionId) was orphaned (no transcript found); starting a fresh session."
        let combined = "echo \(shellSingleQuoted(noticeBody)) && \(launchPart)"
        return materializeStartupInput(
            command: combined,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        )
    }
}

private enum AgentResumeScriptStore {
    private static let directoryName = "cmux-agent-resume"
    private static let scriptTTL: TimeInterval = 24 * 60 * 60

    static func writeLauncherScript(
        command: String,
        kind: RestorableAgentKind,
        sessionId: String,
        fileManager: FileManager,
        temporaryDirectory: URL
    ) -> URL? {
        let directoryURL = temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            pruneOldScripts(in: directoryURL, fileManager: fileManager)

            let safeSessionPrefix = sessionId
                .prefix(12)
                .map { character -> Character in
                    character.isLetter || character.isNumber || character == "-" ? character : "_"
                }
            let scriptURL = directoryURL.appendingPathComponent(
                "\(kind.rawValue)-\(String(safeSessionPrefix))-\(UUID().uuidString).zsh",
                isDirectory: false
            )
            let contents = """
            #!/bin/zsh
            rm -f -- "$0" 2>/dev/null || true
            \(command)
            """
            try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)
            return scriptURL
        } catch {
            return nil
        }
    }

    private static func pruneOldScripts(in directoryURL: URL, fileManager: FileManager) {
        guard let scriptURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-scriptTTL)
        for scriptURL in scriptURLs where scriptURL.pathExtension == "zsh" {
            let values = try? scriptURL.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? fileManager.removeItem(at: scriptURL)
            }
        }
    }
}

private struct RestorableAgentHookSessionRecord: Codable, Sendable {
    var sessionId: String
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
    var launchCommand: AgentLaunchCommandSnapshot?
    var updatedAt: TimeInterval
}

private struct RestorableAgentHookSessionStoreFile: Codable, Sendable {
    var version: Int = 1
    var sessions: [String: RestorableAgentHookSessionRecord] = [:]
}

struct RestorableAgentSessionIndex: Sendable {
    static let empty = RestorableAgentSessionIndex(snapshotsByPanel: [:])

    struct PanelKey: Hashable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
    }

    private let snapshotsByPanel: [PanelKey: SessionRestorableAgentSnapshot]

    func snapshot(workspaceId: UUID, panelId: UUID) -> SessionRestorableAgentSnapshot? {
        snapshotsByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)]
    }

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> RestorableAgentSessionIndex {
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        return load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: [:]
        )
    }

    static func loadIncludingProcessDetectedSnapshots(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> RestorableAgentSessionIndex {
        await Task.detached(priority: .utility) {
            let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
            let detectedSnapshots = processDetectedSnapshots(
                registry: registry,
                fileManager: fileManager
            )
            return load(
                homeDirectory: homeDirectory,
                fileManager: fileManager,
                registry: registry,
                detectedSnapshots: detectedSnapshots
            )
        }.value
    }

    private static func load(
        homeDirectory: String,
        fileManager: FileManager,
        registry: CmuxVaultAgentRegistry,
        detectedSnapshots: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)]
    ) -> RestorableAgentSessionIndex {
        let decoder = JSONDecoder()
        var resolved: [PanelKey: (snapshot: SessionRestorableAgentSnapshot, updatedAt: TimeInterval)] = [:]
        let builtInKindIDs = Set(RestorableAgentKind.allCases.map(\.rawValue))
        let hookKinds: [(kind: RestorableAgentKind, registration: CmuxVaultAgentRegistration?)] =
            RestorableAgentKind.allCases.map { (kind: $0, registration: nil) }
            + registry.registrations.compactMap { registration in
                builtInKindIDs.contains(registration.id)
                    ? nil
                    : (kind: .custom(registration.id), registration: registration)
            }

        for (kind, registration) in hookKinds {
            let fileURL = kind.hookStoreFileURL(homeDirectory: homeDirectory)
            guard fileManager.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let state = try? decoder.decode(RestorableAgentHookSessionStoreFile.self, from: data) else {
                continue
            }

            for record in state.sessions.values {
                let normalizedSessionId = record.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedSessionId.isEmpty,
                      let workspaceId = UUID(uuidString: record.workspaceId),
                      let panelId = UUID(uuidString: record.surfaceId) else {
                    continue
                }

                let snapshot = SessionRestorableAgentSnapshot(
                    kind: kind,
                    sessionId: normalizedSessionId,
                    workingDirectory: normalizedWorkingDirectory(record.cwd),
                    launchCommand: record.launchCommand,
                    registration: registration
                )
                let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
                if let existing = resolved[key], existing.updatedAt > record.updatedAt {
                    continue
                }
                resolved[key] = (snapshot: snapshot, updatedAt: record.updatedAt)
            }
        }

        for (key, detected) in detectedSnapshots {
            if let existing = resolved[key], existing.updatedAt > detected.updatedAt {
                continue
            }
            resolved[key] = detected
        }

        return RestorableAgentSessionIndex(snapshotsByPanel: resolved.mapValues(\.snapshot))
    }

    private static func normalizedWorkingDirectory(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }

    /// Returns true when a Claude transcript for `sessionId` can be located.
    /// Tries the exact `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl` path
    /// first, then falls back to scanning sibling project directories — Claude's
    /// project-slug encoding doesn't always match `cwd.replacingOccurrences(of:)`
    /// (e.g. symlinks, alternate path representations), so a slug mismatch alone
    /// shouldn't trigger orphan-fallback when the transcript actually exists.
    /// Without a cwd we can't even attempt the exact path, so we don't filter —
    /// Claude will surface its own error if the session is missing.
    static func claudeTranscriptExists(
        sessionId: String,
        workingDirectory: String?,
        homeDirectory: String,
        fileManager: FileManager
    ) -> Bool {
        guard let workingDirectory,
              !workingDirectory.isEmpty else {
            return true
        }
        let projectsRoot = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        let encoded = workingDirectory.replacingOccurrences(of: "/", with: "-")
        let exactPath = projectsRoot
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
            .path
        if fileManager.fileExists(atPath: exactPath) {
            return true
        }
        let transcriptName = "\(sessionId).jsonl"
        guard let entries = try? fileManager.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for entry in entries {
            let candidate = entry.appendingPathComponent(transcriptName).path
            if fileManager.fileExists(atPath: candidate) {
                return true
            }
        }
        return false
    }

    private init(snapshotsByPanel: [PanelKey: SessionRestorableAgentSnapshot]) {
        self.snapshotsByPanel = snapshotsByPanel
    }
}
