#if DEBUG
import CMUXDebugLog
import Foundation
import QuartzCore

@inline(__always)
func cmuxDebugLog(_ message: @autoclosure () -> String) {
    CMUXDebugLog.logDebugEvent(message())
}

/// Main-thread hang watchdog. Posts a beacon to the main runloop every ~100ms;
/// a background thread polls how stale the last successful beacon ack is.
/// When the gap exceeds `hangThreshold`, logs `watchdog.hang.start` and shells
/// out to `/usr/bin/sample` to capture a 3-second stack dump to `/tmp`. When
/// the beacon resumes, logs `watchdog.hang.end totalMs=<N>`.
///
/// Sample output path is logged so the next freeze produces a directly-named
/// artifact under /tmp/cmux-hang-sample-<pid>-<unix>.txt.
///
/// CASPER: whole type is Casper-only (upstream has no main-thread hang
/// watchdog); delete if upstream adds its own main-thread stall sampler.
final class MainThreadHangWatchdog: @unchecked Sendable {
    static let shared = MainThreadHangWatchdog()

    /// Retention bound on `/tmp/cmux-hang-sample-*` dumps, newest-first.
    ///
    /// Bounds total disk, not any single instance's history: prune enumerates
    /// the shared `/tmp` globally, so this ~50-dump budget (~150 MB at ~3 MB
    /// each) is split across every concurrently-running tagged build — an
    /// instance's own recent samples can be evicted when several run at once.
    /// That is the intended tradeoff (see docs/casper-fork/hang-watchdog.md); the
    /// problem being solved is cross-launch accumulation — ~20 tagged
    /// reloads/day with nothing ever pruning reached 1.35 GB in five days.
    /// Count, not age, because launch frequency is what drives the total.
    static let defaultRetentionKeepCount = 50

    static let retentionKeepCountEnvKey = "CMUX_HANG_SAMPLE_KEEP"

    private static let samplePrefix = "cmux-hang-sample-"
    private static let sampleSuffix = ".txt"
    private static let sampleDirectory = "/tmp"

    /// Single source of truth for the dump filename shape, shared by the writer
    /// and the parser below. If these drift, pruning silently stops matching.
    static func samplePath(pid: Int32, unix: Int) -> String {
        "\(sampleDirectory)/\(samplePrefix)\(pid)-\(unix)\(sampleSuffix)"
    }

    /// `0` (or any non-positive value) means unlimited — the opt-out for when
    /// you are actively debugging a stall and want every dump kept.
    static func retentionKeepCount(env: [String: String]) -> Int {
        guard let raw = env[retentionKeepCountEnvKey], let parsed = Int(raw) else {
            return defaultRetentionKeepCount
        }
        return parsed
    }

    /// Pure retention policy: of `paths`, the ones to delete so that only the
    /// `keep` newest survive. Ranked by the unix field embedded in the
    /// filename rather than by mtime or lexicographic order — PIDs are
    /// variable-width, so sorting paths as strings orders by PID digits first.
    /// Paths that do not match `cmux-hang-sample-<pid>-<unix>.txt` are never
    /// returned; unrecognised files are not ours to remove.
    static func samplesToPrune(paths: [String], keep: Int) -> [String] {
        guard keep > 0 else { return [] }
        let dated: [(path: String, unix: Int)] = paths.compactMap { path in
            guard let unix = sampleUnixTimestamp(path: path) else { return nil }
            return (path, unix)
        }
        guard dated.count > keep else { return [] }
        // Newest first; tie-break on path so concurrent launches agree on the
        // victim rather than each picking by their own enumeration order.
        let ordered = dated.sorted { lhs, rhs in
            lhs.unix == rhs.unix ? lhs.path > rhs.path : lhs.unix > rhs.unix
        }
        return ordered.dropFirst(keep).map(\.path)
    }

    /// Parses the trailing `<unix>` from `.../cmux-hang-sample-<pid>-<unix>.txt`.
    private static func sampleUnixTimestamp(path: String) -> Int? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix(samplePrefix), name.hasSuffix(sampleSuffix) else { return nil }
        let body = name.dropFirst(samplePrefix.count).dropLast(sampleSuffix.count)
        let fields = body.split(separator: "-")
        guard fields.count == 2, Int(fields[0]) != nil, let unix = Int(fields[1]) else {
            return nil
        }
        return unix
    }

    /// Enumerate + prune. Called off the main thread: once at `start()` (clears
    /// dumps left by earlier launches, which is where the accumulation came
    /// from) and again after each new sample lands, so a long-lived app — the
    /// pinned Casper runs for weeks — stays bounded rather than only being
    /// swept at launch.
    private func pruneSamples() {
        let keep = Self.retentionKeepCount(env: ProcessInfo.processInfo.environment)
        guard keep > 0 else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.sampleDirectory) else { return }
        let paths = names
            .filter { $0.hasPrefix(Self.samplePrefix) }
            .map { Self.sampleDirectory + "/" + $0 }
        let victims = Self.samplesToPrune(paths: paths, keep: keep)
        guard !victims.isEmpty else { return }
        var removed = 0
        for victim in victims where (try? fm.removeItem(atPath: victim)) != nil {
            removed += 1
        }
        cmuxDebugLog("watchdog.sample.prune removed=\(removed) of=\(paths.count) keep=\(keep)")
    }

    private let lock = NSLock()
    private var _lastBeaconAt: CFTimeInterval = CACurrentMediaTime()
    private var lastBeaconAt: CFTimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _lastBeaconAt }
        set { lock.lock(); _lastBeaconAt = newValue; lock.unlock() }
    }

    private let watchdogQueue = DispatchQueue(
        label: "cmux.main-hang-watchdog",
        qos: .userInitiated
    )

    private var sampleInFlight = false
    private var started = false

    private let hangThresholdSeconds: TimeInterval = 0.5
    private let beaconIntervalSeconds: TimeInterval = 0.1
    private let pollIntervalSeconds: TimeInterval = 0.1
    /// Don't kick off another `sample` until the previous one finishes;
    /// also rate-limit so short stutters don't spawn a queue of samplers.
    private let sampleCooldownSeconds: TimeInterval = 5.0
    private var lastSampleAt: CFTimeInterval = 0

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        _lastBeaconAt = CACurrentMediaTime()
        lock.unlock()

        cmuxDebugLog("watchdog.start hangThresholdMs=\(Int(hangThresholdSeconds * 1000)) beaconMs=\(Int(beaconIntervalSeconds * 1000))")
        scheduleBeacon()
        watchdogQueue.async { [weak self] in
            // Before runLoop, which never returns.
            self?.pruneSamples()
            self?.runLoop()
        }
    }

    private func scheduleBeacon() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastBeaconAt = CACurrentMediaTime()
            DispatchQueue.main.asyncAfter(deadline: .now() + self.beaconIntervalSeconds) { [weak self] in
                self?.scheduleBeacon()
            }
        }
    }

    private func runLoop() {
        var hangActive = false
        var hangStartBeacon: CFTimeInterval = 0
        while true {
            Thread.sleep(forTimeInterval: pollIntervalSeconds)
            let now = CACurrentMediaTime()
            let currentBeacon = lastBeaconAt
            let stall = now - currentBeacon
            if stall > hangThresholdSeconds {
                if !hangActive {
                    hangActive = true
                    hangStartBeacon = currentBeacon
                    cmuxDebugLog("watchdog.hang.start stallMs=\(Int(stall * 1000))")
                    triggerSampleIfPossible(stallMs: Int(stall * 1000))
                }
            } else if hangActive {
                hangActive = false
                let totalStall = currentBeacon - hangStartBeacon
                cmuxDebugLog("watchdog.hang.end totalMs=\(Int(totalStall * 1000))")
            }
        }
    }

    private func triggerSampleIfPossible(stallMs: Int) {
        lock.lock()
        let now = CACurrentMediaTime()
        if sampleInFlight || now - lastSampleAt < sampleCooldownSeconds {
            lock.unlock()
            return
        }
        sampleInFlight = true
        lastSampleAt = now
        lock.unlock()

        let pid = ProcessInfo.processInfo.processIdentifier
        let unix = Int(Date().timeIntervalSince1970)
        let path = Self.samplePath(pid: pid, unix: unix)
        let task = Process()
        task.launchPath = "/usr/bin/sample"
        // `sample <pid> 3 -file <path>`: 3-second collection, write to file.
        task.arguments = [String(pid), "3", "-file", path]
        task.terminationHandler = { [weak self] proc in
            cmuxDebugLog("watchdog.sample.done path=\(path) status=\(proc.terminationStatus)")
            guard let self else { return }
            self.lock.lock()
            self.sampleInFlight = false
            self.lock.unlock()
            // After releasing sampleInFlight: a sample racing this prune is
            // newer than every victim, so it survives regardless.
            self.pruneSamples()
        }
        do {
            try task.run()
            cmuxDebugLog("watchdog.sample.start pid=\(pid) stallMs=\(stallMs) path=\(path)")
        } catch {
            cmuxDebugLog("watchdog.sample.error \(error)")
            lock.lock()
            sampleInFlight = false
            lock.unlock()
        }
    }
}
#endif
