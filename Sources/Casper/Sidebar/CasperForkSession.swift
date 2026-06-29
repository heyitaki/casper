import AppKit
import Foundation

// CASPER: "Fork Session" sidebar action. Forks a running claude/codex agent
// into a brand-new workspace — the new terminal resumes the original session's
// history under a *new* session id, leaving the original untouched. Wired into
// the session-row context menu (`CasperSidebarPanelRow`). Delete if upstream
// adds first-class session forking.
enum CasperForkSession {
    /// Cheap, in-memory check used to gate context-menu visibility — runs on
    /// every sidebar render, so it stays allocation- and disk-free. Returns the
    /// forkable agent kind for a panel with a *live* claude/codex agent, or nil.
    ///
    /// The agent kind is recovered from the panel's live PID keys
    /// (`agentPIDKeysByPanelId`): claude registers the literal `"claude_code"`,
    /// every generic agent registers `"<statusKey>.<sessionId>"`. Only claude
    /// and codex support forking today.
    ///
    /// Liveness is verified per key: a SIGKILL'd/crashed agent's key lingers
    /// until the 30s stale-PID sweep, so without this check "Fork Session" would
    /// haunt a dead session's row. `kill(pid, 0)` is the same probe the sweep
    /// uses — a single cheap syscall, only reached after matching a forkable key.
    @MainActor
    static func forkableKind(for workspace: Workspace, panelId: UUID) -> RestorableAgentKind? {
        guard let pidKeys = workspace.agentPIDKeysByPanelId[panelId] else { return nil }
        for key in pidKeys {
            let kind: RestorableAgentKind?
            if key == "claude_code" {
                kind = .claude
            } else if key == "codex" || key.hasPrefix("codex.") {
                kind = .codex
            } else {
                kind = nil
            }
            guard let kind else { continue }
            if let pid = workspace.agentPIDs[key], isProcessAlive(pid) {
                return kind
            }
        }
        return nil
    }

    /// True when `pid` names a running process. Mirrors `TabManager`'s stale-PID
    /// sweep: `kill(pid, 0)` succeeds for a live process, and `EPERM` means the
    /// process exists but is owned by another user (still alive).
    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Resolves the live agent session (authoritative — reads the hook records
    /// from disk) and opens a new workspace running the fork command. Called
    /// lazily from the context-menu action, never per render, so the disk read
    /// is fine. Surfaces an alert when no resumable session is found.
    @MainActor
    static func forkSession(
        tabManager: TabManager,
        workspaceId: UUID,
        panelId: UUID,
        fallbackCwd: String?
    ) {
        guard let snapshot = RestorableAgentSessionIndex.load().snapshot(
            workspaceId: workspaceId,
            panelId: panelId
        ) else {
            presentForkUnavailableAlert()
            return
        }

        let targetCwd = snapshot.workingDirectory ?? fallbackCwd
        guard let command = AgentResumeCommandBuilder.forkShellCommand(
            kind: snapshot.kind,
            sessionId: snapshot.sessionId,
            launchCommand: snapshot.launchCommand,
            workingDirectory: targetCwd
        ) else {
            presentForkUnavailableAlert()
            return
        }

        _ = tabManager.addWorkspace(
            workingDirectory: targetCwd,
            initialTerminalInput: command + "\n"
        )
    }

    @MainActor
    private static func presentForkUnavailableAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "casper.fork.unavailable.title",
            defaultValue: "Can't Fork Session"
        )
        alert.informativeText = String(
            localized: "casper.fork.unavailable.message",
            defaultValue: "No resumable agent session was found for this terminal. Start the agent, then try again."
        )
        alert.runModal()
    }
}
