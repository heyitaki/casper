// CASPER: Recent Swaps panel (Req 10). NSWindowController singleton hosting a
// SwiftUI list of the most recent swap events. The daemon calls
// `recordEvent(_:)` after every swap; the window also re-reads `events.jsonl`
// on open so it survives a daemon restart with its history intact.
//
// `dlopen_pending` breadcrumb events are written by the daemon before dlopen
// so a crash mid-swap leaves a trace; the panel filters them out so the user
// only sees terminal events.

#if DEBUG

import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class CasperHMRDebugWindow: NSObject {
    static let shared = CasperHMRDebugWindow()

    private var window: NSWindow?
    private let model = CasperHMRRecentSwapsModel()

    private override init() {
        super.init()
    }

    /// Called from the Debug menu. Lazily creates the window the first time
    /// it's shown.
    func show() {
        model.refreshFromDisk()
        if window == nil {
            let host = NSHostingController(rootView: CasperHMRRecentSwapsView(model: model))
            let win = NSWindow(contentViewController: host)
            win.title = String(
                localized: "casper.hmr.window.recent_swaps.title",
                defaultValue: "Casper HMR Recent Swaps"
            )
            win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            win.setContentSize(NSSize(width: 720, height: 480))
            win.isReleasedWhenClosed = false
            win.center()
            window = win
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called from `CasperHMRDaemon.writeSwapEvent`. Filters `dlopen_pending`
    /// (it's only a crash breadcrumb, not a terminal event).
    func recordEvent(_ event: CasperHMRSwapEvent) {
        guard event.result != "dlopen_pending" else { return }
        model.append(event)
    }
}

@MainActor
final class CasperHMRRecentSwapsModel: ObservableObject {
    @Published private(set) var events: [CasperHMRSwapEvent] = []

    func append(_ event: CasperHMRSwapEvent) {
        events.append(event)
        let trim = CasperHMRConfig.recentSwapsDisplayCount
        if events.count > trim {
            events.removeFirst(events.count - trim)
        }
    }

    /// Re-hydrate from events.jsonl on window open. Tolerant of malformed
    /// lines — a single bad record doesn't drop the rest of the panel.
    func refreshFromDisk() {
        let path = "\(CasperHMRConfig.stateDirectory())/events.jsonl"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            events = []
            return
        }
        guard let text = String(data: data, encoding: .utf8) else { return }
        var loaded: [CasperHMRSwapEvent] = []
        for line in text.split(separator: "\n") {
            guard let lineData = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            if let event = CasperHMRSwapEvent.fromDict(obj),
               event.result != "dlopen_pending" {
                loaded.append(event)
            }
        }
        let trim = CasperHMRConfig.recentSwapsDisplayCount
        if loaded.count > trim {
            events = Array(loaded.suffix(trim))
        } else {
            events = loaded
        }
    }

    /// p50 / p95 over the displayed window, excluding `unchanged` events.
    var latencyStats: (p50: Int, p95: Int, count: Int) {
        let samples = events
            .filter { $0.result != "unchanged" }
            .map { $0.durationMs }
            .sorted()
        guard !samples.isEmpty else { return (0, 0, 0) }
        let p50Idx = max(0, samples.count / 2 - (samples.count % 2 == 0 ? 1 : 0))
        let p95Idx = max(0, min(samples.count - 1, Int(ceil(0.95 * Double(samples.count))) - 1))
        return (samples[p50Idx], samples[p95Idx], samples.count)
    }
}

private struct CasperHMRRecentSwapsView: View {
    @ObservedObject var model: CasperHMRRecentSwapsModel
    @State private var expandedTimestamp: TimeInterval?

    var body: some View {
        VStack(spacing: 0) {
            list
            Divider()
            statsStrip
        }
    }

    private var list: some View {
        Group {
            if model.events.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.events.reversed(), id: \.ts) { event in
                            CasperHMRSwapRow(
                                event: event,
                                isExpanded: expandedTimestamp == event.ts,
                                onToggle: {
                                    expandedTimestamp = expandedTimestamp == event.ts ? nil : event.ts
                                }
                            )
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        Text(String(
            localized: "casper.hmr.window.recent_swaps.empty",
            defaultValue: "No swaps yet. Save a file in Sources/Casper to trigger one."
        ))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statsStrip: some View {
        let stats = model.latencyStats
        return HStack(spacing: 16) {
            Text("p50 \(stats.p50)ms").monospacedDigit()
            Text("p95 \(stats.p95)ms").monospacedDigit()
            Text("n=\(stats.count)").monospacedDigit().foregroundStyle(.secondary)
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

private struct CasperHMRSwapRow: View {
    let event: CasperHMRSwapEvent
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(relativeTime).frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
                Text((event.path as NSString).lastPathComponent)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Text(event.result)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(resultColor.opacity(0.18))
                    .foregroundStyle(resultColor)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text("\(event.durationMs)ms")
                    .font(.system(.caption, design: .monospaced))
                    .monospacedDigit()
                    .frame(width: 60, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    if !event.matchedSymbols.isEmpty {
                        Text("matched_symbols (\(event.matchedSymbols.count)):").font(.caption).foregroundStyle(.secondary)
                        ForEach(event.matchedSymbols.prefix(20), id: \.self) { sym in
                            Text(sym).font(.system(.caption, design: .monospaced)).lineLimit(1)
                        }
                        if event.matchedSymbols.count > 20 {
                            Text("… \(event.matchedSymbols.count - 20) more").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if event.fieldOffsetPatched != 0
                        || event.fieldOffsetUnchanged != 0
                        || event.fieldOffsetMissing != 0 {
                        Text("field_offsets: patched=\(event.fieldOffsetPatched) unchanged=\(event.fieldOffsetUnchanged) missing=\(event.fieldOffsetMissing)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(event.fieldOffsetMissing > 0 ? .orange : .secondary)
                    }
                    if let reason = event.reason {
                        Text("reason: \(reason)").font(.system(.caption, design: .monospaced))
                    }
                    if let stderrTail = event.stderrTail, !stderrTail.isEmpty {
                        Text("stderr_tail:").font(.caption).foregroundStyle(.secondary)
                        Text(stderrTail).font(.system(.caption, design: .monospaced)).foregroundStyle(.red.opacity(0.85))
                    }
                    if let hash = event.hash {
                        Text("hash: \(hash)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 82)
                .padding(.trailing, 12)
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    private var relativeTime: String {
        let delta = Date().timeIntervalSince1970 - event.ts
        if delta < 1 { return "now" }
        if delta < 60 { return "\(Int(delta))s ago" }
        if delta < 3600 { return "\(Int(delta / 60))m ago" }
        if delta < 86400 { return "\(Int(delta / 3600))h ago" }
        return "\(Int(delta / 86400))d ago"
    }

    /// Result color matches the Debug-menu status item from the spec.
    private var resultColor: Color {
        switch event.result {
        case "ok": return .green
        case "ok_unverified": return .teal
        case "unchanged": return .gray
        case "out_of_envelope_predicted": return .orange
        case "no_interpose": return .yellow
        default: return .red
        }
    }
}

/// Debug-menu section. Lives inline in `cmuxApp.swift`'s CommandMenu("Debug")
/// so the toggle binds to `@AppStorage(CasperHMRConfig.userDefaultsEnabledKey)`
/// — the daemon's UserDefaults observer (Req 5) picks up the change and
/// starts/stops the FSEvents watcher in-process, no app relaunch needed.
struct CasperHMRDebugMenuSection: View {
    @AppStorage(CasperHMRConfig.userDefaultsEnabledKey) private var enabled: Bool = true

    var body: some View {
        Toggle(
            String(
                localized: "casper.hmr.menu.enabled",
                defaultValue: "Casper HMR (CASPER_HMR_NEW)"
            ),
            isOn: $enabled
        )
        Button(
            String(
                localized: "casper.hmr.menu.open_recent_swaps",
                defaultValue: "Open Casper HMR Recent Swaps…"
            )
        ) {
            CasperHMRDebugWindow.shared.show()
        }
    }
}

extension CasperHMRSwapEvent {
    /// Best-effort decoder for events.jsonl rehydration. Returns nil for
    /// missing required fields; tolerates missing optional fields.
    static func fromDict(_ obj: [String: Any]) -> CasperHMRSwapEvent? {
        guard let ts = obj["ts"] as? Double,
              let path = obj["path"] as? String,
              let result = obj["result"] as? String else {
            return nil
        }
        let durationMs = (obj["duration_ms"] as? Int) ?? Int((obj["duration_ms"] as? Double) ?? 0)
        let interposeEntries = (obj["interpose_entries"] as? Int) ?? 0
        let matchedSymbols = (obj["matched_symbols"] as? [String]) ?? []
        let reason = obj["reason"] as? String
        let stderrTail = obj["stderr_tail"] as? String
        let hash = obj["hash"] as? String
        let foPatched = (obj["fo_patched"] as? Int) ?? 0
        let foUnchanged = (obj["fo_unchanged"] as? Int) ?? 0
        let foMissing = (obj["fo_missing"] as? Int) ?? 0
        return CasperHMRSwapEvent(
            ts: ts,
            path: path,
            durationMs: durationMs,
            result: result,
            interposeEntries: interposeEntries,
            matchedSymbols: matchedSymbols,
            reason: reason,
            stderrTail: stderrTail,
            hash: hash,
            fieldOffsetPatched: foPatched,
            fieldOffsetUnchanged: foUnchanged,
            fieldOffsetMissing: foMissing
        )
    }
}

#endif
