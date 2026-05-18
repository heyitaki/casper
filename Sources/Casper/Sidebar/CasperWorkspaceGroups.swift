// CASPER: workspace sidebar grouping by repo path.
// Delete if upstream adds first-class workspace grouping in the sidebar.

import Foundation
import SwiftUI

struct CasperWorkspaceGroup: Identifiable {
    let key: String
    let displayName: String
    let workspaces: [Workspace]
    var id: String { key }
}

@MainActor
enum CasperWorkspaceGroupResolver {
    // Repo roots don't move during a session, so a process-lifetime cache is fine.
    // Keyed by the directory we resolved from (not by repo root) so a `cd` into a
    // subdir still hits cache after the first walk.
    private static var repoRootCache: [String: String?] = [:]

    // Standardized once at process start so the per-keystroke `groupKey` loop
    // doesn't redo `URL.standardizedFileURL` (a symlink-resolving syscall)
    // for every workspace.
    private static let homeKey: String = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path

    /// Resolve the workspace's group from the repo roots of all its panels.
    /// - Panels whose resolved key is the user's home directory are treated as
    ///   "neutral" — new splits often default to `~`, and a workspace already
    ///   anchored to a real repo shouldn't reclassify just because the user
    ///   opened more terminals.
    /// - Among the non-neutral panels, the highest-count repo root wins; ties
    ///   break alphabetically by repo root for stability (so a 1:1 split across
    ///   repos doesn't bounce on focus changes).
    /// - If every panel is in `~`, home is the group.
    /// - Falls back to `currentDirectory` only when no panel has reported a cwd
    ///   yet (early lifecycle, before any OSC 7).
    ///
    /// Reading panel directories (not focused-panel-only) is what stops the
    /// workspace from jumping between groups when the user shifts focus between
    /// two panels in different repos.
    static func groupKey(for workspace: Workspace) -> String {
        var directories: [String] = workspace.panelDirectories.values.compactMap { dir in
            let trimmed = dir.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if directories.isEmpty {
            let cwd = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cwd.isEmpty {
                directories = [cwd]
            }
        }
        guard !directories.isEmpty else { return "" }

        let resolvedKeys = directories.map { dir -> String in
            let raw: String
            if let root = repoRoot(forDirectory: dir) {
                raw = root
            } else {
                raw = URL(fileURLWithPath: dir).standardizedFileURL.path
            }
            // Strip a single trailing slash so `/foo/bar` and `/foo/bar/`
            // never bucket as distinct keys. `URL.path` already does this
            // for non-root paths, but normalize defensively in case the
            // source ever changes.
            if raw.count > 1, raw.hasSuffix("/") {
                return String(raw.dropLast())
            }
            return raw
        }

        let workKeys = resolvedKeys.filter { $0 != Self.homeKey }
        let candidates = workKeys.isEmpty ? resolvedKeys : workKeys

        var counts: [String: Int] = [:]
        for key in candidates {
            counts[key, default: 0] += 1
        }

        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }?.key ?? ""
    }

    static func displayName(forGroupKey key: String) -> String {
        guard !key.isEmpty else { return "" }
        let last = (key as NSString).lastPathComponent
        return last.isEmpty ? key : last
    }

    /// For each key in `keys`, return the shortest trailing path suffix that
    /// uniquely identifies it within the set, joined by `/`. A unique
    /// `…/cmux` stays `cmux`; two `…/cmux` keys extend to `code/cmux` vs
    /// `work/cmux`; deeper collisions keep extending until distinct.
    /// Private so the precondition "no duplicate input keys" is local to this
    /// file (enforced by `groups(from:)`'s bucket-dedup).
    private static func disambiguatedDisplayNames(forKeys keys: [String]) -> [String: String] {
        // Duplicate-safe: if a future caller ever passes the same string twice,
        // keep the first occurrence rather than trapping. `keys` already comes
        // from a deduped bucket today, but the helper shouldn't be a footgun.
        let parts: [String: [String]] = Dictionary(keys.map { key in
            let comps = (key as NSString).pathComponents.filter { $0 != "/" && !$0.isEmpty }
            return (key, comps)
        }, uniquingKeysWith: { first, _ in first })
        var result: [String: String] = [:]
        for key in keys {
            guard let myParts = parts[key], !myParts.isEmpty else {
                // Empty key = workspace hasn't reported a directory yet
                // (no OSC 7 / no `currentDirectory`). With headers always
                // rendered, fall back to a localized placeholder so the
                // group sits beside repo-anchored groups consistently.
                result[key] = key.isEmpty
                    ? String(
                        localized: "sidebar.workspaceGroup.untitled",
                        defaultValue: "Other"
                    )
                    : key
                continue
            }
            var depth = 1
            while depth < myParts.count {
                let mySuffix = Array(myParts.suffix(depth))
                let collides = keys.contains { other in
                    guard other != key, let otherParts = parts[other], otherParts.count >= depth else {
                        return false
                    }
                    return Array(otherParts.suffix(depth)) == mySuffix
                }
                if !collides { break }
                depth += 1
            }
            result[key] = myParts.suffix(depth).joined(separator: "/")
        }
        return result
    }

    /// Group workspaces by repo, preserving first-appearance order so the
    /// underlying `tabs` array remains the source of truth for ordering.
    static func groups(from workspaces: [Workspace]) -> [CasperWorkspaceGroup] {
        var order: [String] = []
        var buckets: [String: [Workspace]] = [:]
        for workspace in workspaces {
            let key = groupKey(for: workspace)
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = [workspace]
            } else {
                buckets[key]?.append(workspace)
            }
        }
        let names = disambiguatedDisplayNames(forKeys: order)
        return order.map { key in
            CasperWorkspaceGroup(
                key: key,
                displayName: names[key, default: ""],
                workspaces: buckets[key] ?? []
            )
        }
    }

    /// First index in `workspaces` that is unpinned and shares `bumped`'s group.
    /// Used as the insertion point so notification-driven bumps land at the top
    /// of the workspace's repo group (below any pinned siblings) rather than the
    /// top of the whole list.
    static func firstUnpinnedIndex(in workspaces: [Workspace], matching bumped: Workspace) -> Int? {
        let key = groupKey(for: bumped)
        return workspaces.firstIndex { workspace in
            !workspace.isPinned && groupKey(for: workspace) == key
        }
    }

    private static func repoRoot(forDirectory directory: String) -> String? {
        guard !directory.isEmpty else { return nil }
        if let cached = repoRootCache[directory] {
            return cached
        }
        let resolved = findRepoRoot(from: directory)
        repoRootCache[directory] = resolved
        return resolved
    }

    private static func findRepoRoot(from directory: String) -> String? {
        var url = URL(fileURLWithPath: directory).standardizedFileURL
        let fileManager = FileManager.default
        // Cap the walk so a pathological path (e.g. symlink loop reduced via
        // standardization can't happen, but defense in depth) can't spin.
        for _ in 0..<64 {
            let gitPath = url.appendingPathComponent(".git").path
            if fileManager.fileExists(atPath: gitPath) {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }
}

struct CasperWorkspaceGroupHeader: View {
    let displayName: String
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.65))
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .animation(.spring(response: 0.28, dampingFraction: 0.88), value: isCollapsed)
                    .frame(width: 10, alignment: .center)
                Image(systemName: "folder.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.55))
                Text(displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(displayName)
        .accessibilityValue(
            isCollapsed
                ? String(localized: "workspace.group.collapsed", defaultValue: "Collapsed")
                : String(localized: "workspace.group.expanded", defaultValue: "Expanded")
        )
        .accessibilityHint(String(
            localized: "workspace.group.toggleHint",
            defaultValue: "Double-tap to toggle workspace group."
        ))
    }
}

/// Per-group collapse state, persisted to UserDefaults.
/// Lives at the sidebar level so it can be observed without violating the
/// snapshot-boundary rule (rows receive only value-typed snapshots from the
/// parent and never reach into this store themselves).
@MainActor
final class CasperWorkspaceGroupCollapseStore: ObservableObject {
    static let shared = CasperWorkspaceGroupCollapseStore()

    private static let defaultsKey = "casperWorkspaceGroupCollapsedKeys"

    @Published private(set) var collapsedKeys: Set<String>

    init(defaults: UserDefaults = .standard) {
        let raw = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        self.collapsedKeys = Set(raw)
    }

    func isCollapsed(_ key: String) -> Bool {
        collapsedKeys.contains(key)
    }

    func toggle(_ key: String, defaults: UserDefaults = .standard) {
        if collapsedKeys.contains(key) {
            collapsedKeys.remove(key)
        } else {
            collapsedKeys.insert(key)
        }
        defaults.set(Array(collapsedKeys).sorted(), forKey: Self.defaultsKey)
    }
}
