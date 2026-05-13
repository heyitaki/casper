// CASPER: Paths, gate flags, and tunables for the casper-hmr daemon. All
// #if DEBUG-only. Release builds physically lack this code. Delete when
// upstream cmux ships an in-process HMR story.

import Foundation

#if DEBUG

enum CasperHMRConfig {
    /// Schema version of `commands.jsonl` / `events.jsonl`. Bump when the
    /// wrapper-emitted record shape changes; daemon rejects mismatched schemas.
    static let schemaVersion: Int = 1

    /// Wrapper version this daemon is paired with. Daemon refuses to load a
    /// `commands.jsonl` produced by a wrapper at a different semver — almost
    /// always means an Xcode upgrade ran the wrapper from a stale install.
    static let pairedWrapperVersion: String = "1.0.0"

    /// Disable switch — set CASPER_HMR_DISABLE=1 to skip daemon boot. Lets the
    /// user bisect HMR-vs-something-else without rebuilding.
    static let environmentDisableKey: String = "CASPER_HMR_DISABLE"

    /// AppStorage key for the Debug menu toggle. Default true: swaps are live
    /// in DEBUG builds unless the user opts out.
    static let userDefaultsEnabledKey: String = "casper.hmr.enabled"

    /// Build sentinel — a string constant we look for in the Release symbol /
    /// strings table during the Test #11 leak check. If a Release build ever
    /// contains this string, the `#if DEBUG` exclusion is broken.
    static let buildSentinel: String = "casper-hmr-build-sentinel-do-not-strip"

    /// FSEvents debounce window. Two saves landing within this window collapse
    /// into a single compile.
    static let debounceMilliseconds: Int = 100

    /// File-stability poll interval (Req 11): two stat() snapshots this far
    /// apart must agree before we proceed.
    static let fileStabilityIntervalMilliseconds: Int = 50

    /// Maximum file-stability cycles before giving up with result=unstable_file.
    static let fileStabilityMaxCycles: Int = 5

    /// Per-subprocess timeout for swiftc, ld, codesign. Hard kill on overrun.
    static let subprocessTimeoutSeconds: TimeInterval = 5

    /// p95 latency budget — informational; the latency-regression test is
    /// env-gated. Update to `ceil(measured_p95 * 1.5)` once dogfood numbers
    /// settle.
    static let p95BudgetMilliseconds: Int = 1500

    /// Dylib-dir size bounds (Req 6). Eviction happens after every swap.
    static let dylibDirMaxFiles: Int = 500
    static let dylibDirMaxBytes: Int64 = 500 * 1024 * 1024

    /// Rolling latency window size (excluding result=unchanged events).
    static let latencyWindowSize: Int = 100

    /// `events.jsonl` is rewritten to the last N entries at daemon launch.
    static let eventsJSONLRetention: Int = 1000

    /// Recent Swaps panel displays this many events.
    static let recentSwapsDisplayCount: Int = 50

    /// Source-change classifier mode (Req 21). `.gate` blocks recompile when
    /// the classifier predicts out-of-envelope; `.advisory` compiles anyway
    /// and surfaces the prediction in the Recent Swaps panel. Defaults to
    /// `.gate`; flip to `.advisory` if dogfood FP rate exceeds 20%.
    static let classifierMode: ClassifierMode = .gate

    enum ClassifierMode {
        case gate
        case advisory
    }

    /// Resolve the per-tag state directory under `~/.casper/hmr/`. Reads
    /// CASPER_HMR_TAG verbatim; daemon refuses to start under "agent" or when
    /// the value fails the sanity regex (per Req 7).
    static func stateDirectory() -> String {
        let env = ProcessInfo.processInfo.environment
        let tag = env["CASPER_HMR_TAG"] ?? ""
        let home = env["HOME"] ?? NSHomeDirectory()
        return "\(home)/.casper/hmr/\(tag.isEmpty ? "agent" : tag)"
    }

    /// Tag-slug sanity regex. Daemon does not re-sanitize — `reload.sh:146`
    /// produces the slug exactly once. Anything that fails this check
    /// triggers boot-time refusal.
    static let tagSlugRegex: String = "^[a-z0-9-]+$"

    /// Sentinel reserved as build-time fallback only; the runtime daemon
    /// refuses to start under it.
    static let buildOnlyTagSentinel: String = "agent"

    /// Wrapper binary path — referenced by the xcconfig and the daemon's
    /// security check (Req 18 / wrapper-owned-by-user gate).
    static func wrapperBinaryPath() -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return "\(home)/.casper/hmr/tools/bin/casper-swiftc-wrapper"
    }

    /// Production bundle ID; if a Dock-launched cmux ever boots with this
    /// bundle id, the daemon refuses to start (DEBUG-only is the contract).
    static let productionBundleIdentifier: String = "com.cmuxterm.app"
}

/// Newtype wrapper around a canonical (symlink-resolved, standardized) path.
/// Use this as the key for daemon maps so the "did I forget to canonicalize?"
/// bug class is unrepresentable (Req 16).
struct CasperHMRCanonicalPath: Hashable, CustomStringConvertible {
    let rawValue: String

    init(_ path: String) {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        self.rawValue = url.path
    }

    init(url: URL) {
        self.init(url.path)
    }

    var description: String { rawValue }
    var basename: String { (rawValue as NSString).lastPathComponent }
}

#endif
