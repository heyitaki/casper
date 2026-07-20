// CASPER: always-on new-workspace directory inheritance for branded builds.
// Delete if upstream makes selected-workspace directory inheritance unconditional.

import Foundation

struct CasperWorkspaceDirectoryResolver {
    private let homeDirectory: String

    init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.homeDirectory = homeDirectory
    }

    func resolve(selectedWorkspaceDirectory: String?) -> String {
        guard let selectedWorkspaceDirectory else { return homeDirectory }
        let trimmed = selectedWorkspaceDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? homeDirectory : trimmed
    }
}
