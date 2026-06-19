// CASPER: In-app reload button for the titlebar/sidebar icon cluster. Spawns
// a detached `reload.sh --tag <tag> --name "<display>" --launch` for the
// currently running tag. DEBUG-only and Casper-only — delete if upstream
// adds a generic dev-reload affordance.

#if DEBUG
import AppKit
import SwiftUI

/// Resolves the tag + repo root + display name baked into the running app's
/// LSEnvironment by `scripts/reload.sh`. Returns nil if any piece is missing
/// — that happens for untagged or non-dev builds, and the button hides itself
/// in that case so we never offer a rebuild we can't actually run.
struct CasperReloadContext {
    let tag: String
    let repoRoot: String
    let displayName: String

    /// Cached once per process. Env and Info.plist are immutable for the
    /// app's lifetime; `body` re-evaluates dozens of times per minute, so
    /// repeating the `ProcessInfo.environment` dict materialization is waste.
    static let current: CasperReloadContext? = {
        let env = ProcessInfo.processInfo.environment
        guard let tag = env["CMUX_TAG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tag.isEmpty else {
            return nil
        }
        guard let repoRoot = env["CMUXTERM_REPO_ROOT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !repoRoot.isEmpty else {
            return nil
        }
        let displayName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Casper Preview"
        return CasperReloadContext(tag: tag, repoRoot: repoRoot, displayName: displayName)
    }()
}

struct CasperReloadTitlebarButton: View {
    let config: TitlebarControlsStyleConfig
    /// Tint forwarded from the surrounding controls group (upstream's
    /// TitlebarControlButton requires it).
    let foregroundColor: Color
    /// True once the user clicks reload. Stays true until reload.sh's terminal
    /// `pkill` takes this process down (the new app launches fresh with the
    /// state reset to false). The 3-minute fallback below only reactivates the
    /// button if the build *fails* — in the success path the spinner just runs
    /// out the clock until pkill.
    @State private var isReloading = false

    /// Single source of truth for whether this button mounts. Other layout
    /// code (titlebar hint positioning) reads this so the gate can't drift.
    static var isRendered: Bool {
        CasperBuildEnvironment.isBranded && CasperReloadContext.current != nil
    }

    var body: some View {
        if Self.isRendered, let ctx = CasperReloadContext.current {
            TitlebarControlButton(
                config: config,
                foregroundColor: foregroundColor,
                accessibilityIdentifier: "titlebarControl.casperReload",
                accessibilityLabel: "Reload \(ctx.displayName)",
                action: {
                    // Log BEFORE the guard so even a stuck-`isReloading` state
                    // produces an event — that distinguishes "click never
                    // reached the action" from "click denied by gate".
                    // NSLog mirrors to Console.app/syslog independently of our
                    // debug-log file handle in case the latter is misconfigured.
                    let wasReloading = isReloading
                    cmuxDebugLog("titlebar.casperReload.tap tag=\(ctx.tag) wasReloading=\(wasReloading)")
                    NSLog("[casper] titlebar.casperReload.tap tag=%@ wasReloading=%@", ctx.tag, String(wasReloading))
                    guard !wasReloading else {
                        cmuxDebugLog("titlebar.casperReload.skip tag=\(ctx.tag) reason=alreadyReloading")
                        return
                    }
                    isReloading = true
                    let spawned = CasperReloadLauncher.launch(ctx: ctx)
                    cmuxDebugLog("titlebar.casperReload.launch tag=\(ctx.tag) spawned=\(spawned)")
                    NSLog("[casper] titlebar.casperReload.launch tag=%@ spawned=%@", ctx.tag, String(spawned))
                    if !spawned {
                        // Spawn itself failed (missing bash, missing repo,
                        // sandbox denial). The terminal pkill will never fire,
                        // so reset immediately instead of stranding the button.
                        isReloading = false
                        return
                    }
                    // Safety net for failed *builds*: reload.sh exits non-zero
                    // before its pkill step (zig/xcodebuild/codesign failure),
                    // so without this the button stays spinning forever.
                    // 180s comfortably exceeds a clean rebuild (~25s).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [tag = ctx.tag] in
                        cmuxDebugLog("titlebar.casperReload.safetyReset tag=\(tag)")
                        isReloading = false
                    }
                }
            ) {
                ZStack {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: config.iconSize, weight: .semibold))
                        .opacity(isReloading ? 0 : 1)

                    if isReloading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    }
                }
                .frame(width: config.buttonSize, height: config.buttonSize)
            }
            .disabled(isReloading)
            .safeHelp(
                isReloading
                    ? "Rebuilding \(ctx.displayName)…"
                    : "Rebuild \(ctx.displayName) (./scripts/reload.sh --tag \(ctx.tag) --launch)"
            )
            .onAppear {
                cmuxDebugLog("titlebar.casperReload.mount tag=\(ctx.tag) isReloading=\(isReloading)")
            }
            .onDisappear {
                cmuxDebugLog("titlebar.casperReload.unmount tag=\(ctx.tag) isReloading=\(isReloading)")
            }
        }
    }
}

private enum CasperReloadLauncher {
    /// Spawn reload.sh fully detached so the shell survives the upcoming
    /// `pkill` that reload.sh issues against the running app at the end of
    /// the build. Output is teed to a tag-scoped log for post-mortem.
    /// Returns true if the spawn succeeded (the build itself may still fail
    /// later — the safety-net timeout in the caller handles that case).
    static func launch(ctx: CasperReloadContext) -> Bool {
        let script = "\(ctx.repoRoot)/scripts/reload.sh"
        let logPath = "/tmp/cmux-casper-reload-\(ctx.tag).log"

        let shellCommand = """
        cd \(shellEscape(ctx.repoRoot)) && \
        exec \(shellEscape(script)) --tag \(shellEscape(ctx.tag)) --name \(shellEscape(ctx.displayName)) --launch \
            >> \(shellEscape(logPath)) 2>&1
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // `setsid`-equivalent on macOS: `nohup` + detached stdio keeps the
        // child alive when reload.sh later kills our parent app.
        // Outer redirect truncates; the inner `exec reload.sh ... >> log` then
        // appends within this click. Net effect: one fresh log per click,
        // bounded growth across months of dev use.
        process.arguments = ["-lc", "nohup bash -lc \(shellEscape(shellCommand)) </dev/null > \(shellEscape(logPath)) 2>&1 & disown; exit 0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = augmentedEnvironment()

        cmuxDebugLog("titlebar.casperReload.spawn.attempt tag=\(ctx.tag) script=\(script) logPath=\(logPath)")

        do {
            try process.run()
            cmuxDebugLog("titlebar.casperReload.spawn.ok tag=\(ctx.tag) pid=\(process.processIdentifier)")
            NSLog("[casper] titlebar.casperReload.spawn.ok tag=%@ pid=%d", ctx.tag, Int(process.processIdentifier))
            return true
        } catch {
            cmuxDebugLog("titlebar.casperReload.spawn.failed tag=\(ctx.tag) error=\(error)")
            NSLog("[casper] titlebar.casperReload.spawn.failed tag=%@ error=%@", ctx.tag, String(describing: error))
            return false
        }
    }

    /// GUI-launched .apps inherit a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`),
    /// so Homebrew tools that `reload.sh` and `ensure-ghosttykit.sh` need
    /// (`zig`, `xcrun` is fine but `shasum`/`git`/`python3` work) are not on
    /// PATH from `bash -lc`. Prepending the standard Homebrew bin dirs lets
    /// the spawned shell find them without depending on user dotfiles
    /// (matters because the user's login shell is often fish or zsh, so
    /// `bash -lc` doesn't source the same profile).
    private static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let brewPaths = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let existingSet = Set(existing.split(separator: ":").map(String.init))
        let prepend = brewPaths.filter { !existingSet.contains($0) }
        if !prepend.isEmpty {
            env["PATH"] = (prepend + [existing]).joined(separator: ":")
        }
        return env
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
