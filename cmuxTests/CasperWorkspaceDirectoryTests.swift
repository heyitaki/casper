// CASPER: Behavior tests for persisted recent workspace directories and the
// always-on selected-workspace directory resolver.

import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Casper workspace directories")
struct CasperWorkspaceDirectoryTests {
    @Test
    func recentsAreMostRecentFirstAndCanonicalDuplicatesMoveToFront() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let first = try context.makeDirectory("first")
        let second = try context.makeDirectory("second")
        let store = context.makeStore()

        store.record(first.path)
        store.record(second.path)
        store.record(first.appending(path: "..").appending(path: "first").path)

        #expect(store.recentDirectories() == [first.path, second.path])
    }

    @Test
    func persistedRecentsRespectTheConfiguredCap() throws {
        let context = try makeContext(persistedLimit: 3)
        defer { context.cleanup() }
        let directories = try (0..<4).map { try context.makeDirectory("directory-\($0)") }
        let store = context.makeStore()

        for directory in directories {
            store.record(directory.path)
        }

        #expect(store.recentDirectories() == directories.suffix(3).reversed().map(\.path))
    }

    @Test
    func requestedDisplayLimitReturnsOnlyTheMostRecentDirectories() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let directories = try (0..<8).map { try context.makeDirectory("display-directory-\($0)") }
        let store = context.makeStore()

        for directory in directories {
            store.record(directory.path)
        }

        #expect(store.recentDirectories(limit: 7) == directories.suffix(7).reversed().map(\.path))
    }

    @Test
    func recentsPersistAcrossStoreInstances() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let directory = try context.makeDirectory("persisted")

        context.makeStore().record(directory.path)

        #expect(context.makeStore().recentDirectories() == [directory.path])
    }

    @Test
    func nonexistentRecentsArePrunedFromPersistence() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let existing = try context.makeDirectory("existing")
        let missing = context.root.appending(path: "missing")
        let store = context.makeStore()
        store.record(existing.path)
        store.record(missing.path)

        #expect(store.recentDirectories() == [existing.path])
        #expect(context.defaults.stringArray(forKey: context.persistenceKey) == [existing.path])
        #expect(context.makeStore().recentDirectories() == [existing.path])
    }

    @Test
    func resolverUsesTheSelectedWorkspaceDirectory() {
        let resolver = CasperWorkspaceDirectoryResolver(homeDirectory: "/Users/tester")

        #expect(resolver.resolve(selectedWorkspaceDirectory: "/Users/tester/code/cmux") == "/Users/tester/code/cmux")
    }

    @Test(arguments: [nil, "", "   \n"])
    func resolverFallsBackToHomeWhenTheSelectedDirectoryIsUnavailable(selectedDirectory: String?) {
        let resolver = CasperWorkspaceDirectoryResolver(homeDirectory: "/Users/tester")

        #expect(resolver.resolve(selectedWorkspaceDirectory: selectedDirectory) == "/Users/tester")
    }

    @Test @MainActor
    func restoringSessionSnapshotDoesNotRecordDirectoriesThroughTheCreationSeam() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let recent = try context.makeDirectory("recent")
        let restoredFirst = try context.makeDirectory("restored-first")
        let restoredSecond = try context.makeDirectory("restored-second")
        let store = context.makeStore()
        let source = TabManager(initialWorkingDirectory: restoredFirst.path)
        source.addWorkspace(workingDirectory: restoredSecond.path)
        let snapshot = source.sessionSnapshot(includeScrollback: false)
        let restored = RecentRecordingTabManager()
        restored.recentStore = store
        store.record(recent.path)

        restored.restoreSessionSnapshot(snapshot)

        #expect(store.recentDirectories() == [recent.path])
    }

    private func makeContext(persistedLimit: Int = 30) throws -> TestContext {
        let suiteName = "CasperWorkspaceDirectoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let root = FileManager.default.temporaryDirectory
            .appending(path: suiteName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return TestContext(
            root: root,
            defaults: defaults,
            suiteName: suiteName,
            persistenceKey: "recentDirectories",
            persistedLimit: persistedLimit
        )
    }

    private struct TestContext {
        let root: URL
        let defaults: UserDefaults
        let suiteName: String
        let persistenceKey: String
        let persistedLimit: Int

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        func makeDirectory(_ name: String) throws -> URL {
            let directory = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.standardizedFileURL.resolvingSymlinksInPath()
        }

        func makeStore() -> CasperRecentWorkspaceDirectoryStore {
            CasperRecentWorkspaceDirectoryStore(
                defaults: defaults,
                fileManager: .default,
                persistenceKey: persistenceKey,
                persistedLimit: persistedLimit
            )
        }
    }

    @MainActor
    private final class RecentRecordingTabManager: TabManager {
        var recentStore: CasperRecentWorkspaceDirectoryStore?

        override func makeWorkspaceForCreation(
            title: String,
            workingDirectory: String?,
            portOrdinal: Int,
            configTemplate: CmuxSurfaceConfigTemplate?,
            initialTerminalCommand: String?,
            initialTerminalInput: String? = nil,
            initialTerminalEnvironment: [String: String]
        ) -> Workspace {
            let workspace = super.makeWorkspaceForCreation(
                title: title,
                workingDirectory: workingDirectory,
                portOrdinal: portOrdinal,
                configTemplate: configTemplate,
                initialTerminalCommand: initialTerminalCommand,
                initialTerminalInput: initialTerminalInput,
                initialTerminalEnvironment: initialTerminalEnvironment
            )
            recentStore?.record(workspace.currentDirectory)
            return workspace
        }
    }
}
