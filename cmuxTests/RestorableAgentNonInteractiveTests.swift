import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RestorableAgentNonInteractiveTests: XCTestCase {
    func testHookStoreDirectoryCanBeOverriddenForTests() {
        let url = RestorableAgentKind.codex.hookStoreFileURL(
            homeDirectory: "/Users/example",
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": "/tmp/cmux hook state"]
        )

        XCTAssertEqual(url.path, "/tmp/cmux hook state/codex-hook-sessions.json")
    }

    func testNonInteractiveAgentLaunchesAreNotAutoRestored() {
        let claudePrint = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "claude",
                arguments: ["claude", "--print", "summarize this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let claudePrintEquals = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "claude-session-456",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "claude",
                arguments: ["claude", "--print=summarize this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let codexExec = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "codex-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "codex",
                arguments: ["codex", "exec", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let opencodeRun = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "opencode",
                arguments: ["opencode", "run", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let opencodePR = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "opencode-pr-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "opencode",
                arguments: ["opencode", "pr", "123"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let geminiPrompt = SessionRestorableAgentSnapshot(
            kind: .gemini,
            sessionId: "gemini-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "gemini",
                executablePath: "gemini",
                arguments: ["gemini", "--prompt", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let grokSingle = SessionRestorableAgentSnapshot(
            kind: .grok,
            sessionId: "grok-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "grok",
                executablePath: "grok",
                arguments: ["grok", "--single", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let rovoDevAuth = SessionRestorableAgentSnapshot(
            kind: .rovodev,
            sessionId: "rovo-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "rovodev",
                executablePath: "acli",
                arguments: ["acli", "rovodev", "auth", "login"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let hermesOneShot = SessionRestorableAgentSnapshot(
            kind: .hermesAgent,
            sessionId: "hermes-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "hermes-agent",
                executablePath: "hermes",
                arguments: ["hermes", "--oneshot", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let cursorPrint = SessionRestorableAgentSnapshot(
            kind: .cursor,
            sessionId: "cursor-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "cursor",
                executablePath: "cursor-agent",
                arguments: ["cursor-agent", "--print", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let copilotPrompt = SessionRestorableAgentSnapshot(
            kind: .copilot,
            sessionId: "copilot-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "copilot",
                executablePath: "copilot",
                arguments: ["copilot", "--prompt", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let codeBuddyPrint = SessionRestorableAgentSnapshot(
            kind: .codebuddy,
            sessionId: "codebuddy-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codebuddy",
                executablePath: "codebuddy",
                arguments: ["codebuddy", "--print", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let factoryExec = SessionRestorableAgentSnapshot(
            kind: .factory,
            sessionId: "factory-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "factory",
                executablePath: "droid",
                arguments: ["droid", "exec", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )
        let qoderPrint = SessionRestorableAgentSnapshot(
            kind: .qoder,
            sessionId: "qoder-session-123",
            workingDirectory: nil,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "qoder",
                executablePath: "qodercli",
                arguments: ["qodercli", "--print", "fix this"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: nil
            )
        )

        XCTAssertNil(claudePrint.resumeCommand)
        XCTAssertNil(claudePrintEquals.resumeCommand)
        XCTAssertNil(codexExec.resumeCommand)
        XCTAssertNil(opencodeRun.resumeCommand)
        XCTAssertNil(opencodePR.resumeCommand)
        XCTAssertNil(geminiPrompt.resumeCommand)
        XCTAssertNil(grokSingle.resumeCommand)
        XCTAssertNil(rovoDevAuth.resumeCommand)
        XCTAssertNil(hermesOneShot.resumeCommand)
        XCTAssertNil(cursorPrint.resumeCommand)
        XCTAssertNil(copilotPrompt.resumeCommand)
        XCTAssertNil(codeBuddyPrint.resumeCommand)
        XCTAssertNil(factoryExec.resumeCommand)
        XCTAssertNil(qoderPrint.resumeCommand)
    }

    func testClaudeOrphanHookEntryFallsBackToFreshLaunchWithNotice() throws {
        let fileManager = FileManager.default
        let homeDirectory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true
        )
        defer { try? fileManager.removeItem(at: homeDirectory) }

        let cwd = homeDirectory.appendingPathComponent("workspaces/code-cmux").path
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: cwd, isDirectory: true),
            withIntermediateDirectories: true
        )

        let orphan = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "orphan-session-aaaa-bbbb",
            workingDirectory: cwd,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/bin/claude",
                arguments: ["/opt/bin/claude", "--dangerously-skip-permissions"],
                workingDirectory: cwd,
                environment: nil,
                capturedAt: nil,
                source: "test"
            )
        )

        let temporaryDirectory = homeDirectory.appendingPathComponent("tmp", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let startup = orphan.resumeStartupInput(
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory,
            homeDirectory: homeDirectory.path
        )

        XCTAssertNotNil(startup, "orphan should produce a fresh-launch fallback startup input")
        let input = startup ?? ""
        // The fresh-launch path runs through the script store for any non-trivially-short
        // command, so check both the inline and script-launching shapes.
        let inlineHasNotice = input.contains("cmux: previous Claude session orphan-session-aaaa-bbbb was orphaned")
            && input.contains("'/opt/bin/claude' '--dangerously-skip-permissions'")
            && !input.contains("--resume")
        if !inlineHasNotice {
            XCTAssertTrue(input.hasPrefix("/bin/zsh "), "expected zsh script invocation, got: \(input)")
            let scriptPath = String(input.dropFirst("/bin/zsh ".count).dropLast(/* trailing \n */ 1))
                .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            let body = try String(contentsOfFile: scriptPath, encoding: .utf8)
            XCTAssertTrue(body.contains("cmux: previous Claude session orphan-session-aaaa-bbbb was orphaned"))
            XCTAssertTrue(body.contains("'/opt/bin/claude' '--dangerously-skip-permissions'"))
            XCTAssertFalse(body.contains("--resume"))
        }
    }

    func testClaudeWithTranscriptOnDiskStillProducesResumeStartup() throws {
        let fileManager = FileManager.default
        let homeDirectory = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
            create: true
        )
        defer { try? fileManager.removeItem(at: homeDirectory) }

        let cwd = homeDirectory.appendingPathComponent("workspaces/code-cmux").path
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: cwd, isDirectory: true),
            withIntermediateDirectories: true
        )

        let sessionId = "live-session-cccc-dddd"
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
        let projectsDir = homeDirectory
            .appendingPathComponent(".claude/projects/\(encoded)", isDirectory: true)
        try fileManager.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        // Non-empty: claudeTranscriptFileExists requires size > 0 (regularNonEmptyFileExists),
        // so a zero-byte fixture file is indistinguishable from "no transcript" and would
        // silently fall through to the fresh-launch path instead of the one under test.
        try Data(#"{"type":"summary"}"#.utf8).write(to: projectsDir.appendingPathComponent("\(sessionId).jsonl"))

        let live = SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: sessionId,
            workingDirectory: cwd,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/bin/claude",
                arguments: ["/opt/bin/claude"],
                workingDirectory: cwd,
                environment: nil,
                capturedAt: nil,
                source: "test"
            )
        )

        let temporaryDirectory = homeDirectory.appendingPathComponent("tmp", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let startup = live.resumeStartupInput(
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory,
            homeDirectory: homeDirectory.path
        )
        XCTAssertNotNil(startup)
        XCTAssertTrue(startup?.contains("--resume") == true)
        XCTAssertFalse(startup?.contains("cmux: previous Claude session") ?? false)
    }

    func testClaudeTranscriptExistenceFallsBackToTrueWithoutCwd() {
        XCTAssertTrue(RestorableAgentSessionIndex.claudeTranscriptExists(
            sessionId: "any-session",
            workingDirectory: nil,
            homeDirectory: NSHomeDirectory(),
            fileManager: .default
        ))
    }

    // CASPER: "Fork Session" sidebar action builds its command through
    // AgentResumeCommandBuilder.forkShellCommand. These assert the per-agent
    // fork CLI shape (claude --fork-session flag vs codex `fork` subcommand)
    // and that non-forkable kinds yield nil.
    func testForkShellCommandClaudeAppendsForkSessionFlag() {
        let command = AgentResumeCommandBuilder.forkShellCommand(
            kind: .claude,
            sessionId: "sess-1234",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/bin/claude",
                arguments: ["/opt/bin/claude"],
                workingDirectory: "/work/repo",
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: "/work/repo"
        )
        let unwrapped = try? XCTUnwrap(command)
        XCTAssertNotNil(unwrapped)
        guard let unwrapped else { return }
        XCTAssertTrue(unwrapped.contains("--resume"), unwrapped)
        XCTAssertTrue(unwrapped.contains("sess-1234"), unwrapped)
        XCTAssertTrue(unwrapped.contains("--fork-session"), unwrapped)
        let expectedPrefix = TerminalStartupWorkingDirectoryPrefix.optionalChangeDirectoryPrefix(for: "/work/repo")
        XCTAssertNotNil(expectedPrefix)
        if let expectedPrefix {
            XCTAssertTrue(unwrapped.contains(expectedPrefix), unwrapped)
        }
    }

    func testForkShellCommandCodexUsesForkSubcommandNotResume() {
        let command = AgentResumeCommandBuilder.forkShellCommand(
            kind: .codex,
            sessionId: "rollout-9876",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/opt/bin/codex",
                arguments: ["/opt/bin/codex"],
                workingDirectory: "/work/repo",
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: "/work/repo"
        )
        let unwrapped = try? XCTUnwrap(command)
        XCTAssertNotNil(unwrapped)
        guard let unwrapped else { return }
        XCTAssertTrue(unwrapped.contains("'fork'"), unwrapped)
        XCTAssertTrue(unwrapped.contains("rollout-9876"), unwrapped)
        XCTAssertFalse(unwrapped.contains("'resume'"), unwrapped)
    }

    func testForkShellCommandNilForNonForkableKindAndEmptySession() {
        XCTAssertNil(AgentResumeCommandBuilder.forkShellCommand(
            kind: .gemini,
            sessionId: "sess-1234",
            launchCommand: nil,
            workingDirectory: "/work/repo"
        ))
        XCTAssertNil(AgentResumeCommandBuilder.forkShellCommand(
            kind: .claude,
            sessionId: "   ",
            launchCommand: nil,
            workingDirectory: "/work/repo"
        ))
    }

    // CASPER: a codex session whose own launch was `codex fork <parent> …`
    // (e.g. produced by Fork Session itself) must stay forkable AND resumable.
    // The sanitizer hard-blocks a leading `fork`, so the shared codex argv
    // builder peels the leading `fork <parent>` and substitutes the new id.
    // Realistic-shaped codex session identifiers: looksLikeCodexSessionIdentifier requires
    // either a "019" prefix or a >=20-char hex/dash string, matching real codex rollout IDs.
    // Short human-readable placeholders (e.g. "parent-1111") don't satisfy this and silently
    // skip the fork-positional stripping this test exists to exercise.
    private func codexForkLaunchedSnapshot() -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: "01997c3a-eeee-7fff-8000-111111111111",
            workingDirectory: "/work",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/opt/bin/codex",
                arguments: ["/opt/bin/codex", "fork", "01997c3a-aaaa-7bbb-8ccc-dddddddddddd", "-m", "gpt-x"],
                workingDirectory: "/work",
                environment: nil,
                capturedAt: nil,
                source: "test"
            )
        )
    }

    func testForkShellCommandCodexForkLaunchedSessionStripsParentFork() {
        let snapshot = codexForkLaunchedSnapshot()
        let command = AgentResumeCommandBuilder.forkShellCommand(
            kind: snapshot.kind,
            sessionId: snapshot.sessionId,
            launchCommand: snapshot.launchCommand,
            workingDirectory: snapshot.workingDirectory
        )
        let unwrapped = try? XCTUnwrap(command)
        XCTAssertNotNil(unwrapped)
        guard let unwrapped else { return }
        XCTAssertTrue(unwrapped.contains("'fork'"), unwrapped)
        XCTAssertTrue(unwrapped.contains("01997c3a-eeee-7fff-8000-111111111111"), unwrapped)
        XCTAssertTrue(unwrapped.contains("'-m' 'gpt-x'"), unwrapped)
        XCTAssertFalse(unwrapped.contains("01997c3a-aaaa-7bbb-8ccc-dddddddddddd"), unwrapped)
    }

    func testResumeCommandCodexForkLaunchedSessionIsResumable() {
        // Previously nil: the sanitizer rejected the leading `fork`. Routing
        // resume through the shared builder makes such a session resumable.
        let command = try? XCTUnwrap(codexForkLaunchedSnapshot().resumeCommand)
        XCTAssertNotNil(command)
        guard let command else { return }
        XCTAssertTrue(command.contains("'resume'"), command)
        XCTAssertTrue(command.contains("01997c3a-eeee-7fff-8000-111111111111"), command)
        XCTAssertTrue(command.contains("'-m' 'gpt-x'"), command)
        XCTAssertFalse(command.contains("01997c3a-aaaa-7bbb-8ccc-dddddddddddd"), command)
        XCTAssertFalse(command.contains("'fork'"), command)
    }
}
