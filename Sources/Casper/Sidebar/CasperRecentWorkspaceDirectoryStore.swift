// CASPER: persisted workspace-directory MRU for the sidebar new-workspace menu.
// Delete if upstream adds a first-class recent workspace directory store.

import Foundation

struct CasperRecentWorkspaceDirectoryStore {
    private static let defaultPersistenceKey = "casper.sidebar.recentWorkspaceDirectories.v1"

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let persistedLimit: Int
    private let persistenceKey: String

    init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        persistenceKey: String = Self.defaultPersistenceKey,
        persistedLimit: Int = 30
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.persistenceKey = persistenceKey
        self.persistedLimit = max(1, persistedLimit)
    }

    func recentDirectories(limit: Int = .max) -> [String] {
        let persisted = normalizedPersistedDirectories()
        let existing = persisted.filter(isExistingDirectory)
        if existing != persisted {
            defaults.set(existing, forKey: persistenceKey)
        }
        return Array(existing.prefix(max(0, limit)))
    }

    func record(_ directory: String) {
        guard let canonicalDirectory = canonicalDirectory(directory) else { return }
        var next = normalizedPersistedDirectories()
        next.removeAll { $0 == canonicalDirectory }
        next.insert(canonicalDirectory, at: 0)
        defaults.set(Array(next.prefix(persistedLimit)), forKey: persistenceKey)
    }

    private func canonicalDirectory(_ directory: String) -> String? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func isExistingDirectory(_ directory: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func normalizedPersistedDirectories() -> [String] {
        var seen: Set<String> = []
        return (defaults.stringArray(forKey: persistenceKey) ?? []).compactMap { directory in
            guard let canonicalDirectory = canonicalDirectory(directory),
                  seen.insert(canonicalDirectory).inserted else {
                return nil
            }
            return canonicalDirectory
        }
    }
}
