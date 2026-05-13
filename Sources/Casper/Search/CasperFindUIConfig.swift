// CASPER: Flag gate (env > Info.plist > brand-name fallback) for the VS Code-style grouped Find-sidebar UI.

import Foundation

enum CasperFindUIConfig {
    static let useGroupedFindResults: Bool = CasperBuildEnvironment.flag(
        envKey: "CMUX_CASPER_FIND_UI",
        plistKey: "CasperFindUIEnabled"
    )
}
