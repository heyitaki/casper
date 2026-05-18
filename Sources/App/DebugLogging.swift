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
final class MainThreadHangWatchdog: @unchecked Sendable {
    static let shared = MainThreadHangWatchdog()

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
        let path = "/tmp/cmux-hang-sample-\(pid)-\(unix).txt"
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
