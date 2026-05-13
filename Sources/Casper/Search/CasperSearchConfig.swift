// CASPER: Flag gate (env > Info.plist > brand-name fallback) for ranked grouping of Find-sidebar ripgrep results.

import Foundation

enum CasperSearchConfig {
    static let rankFindResults: Bool = CasperBuildEnvironment.flag(
        envKey: "CMUX_CASPER_SEARCH_RANKING",
        plistKey: "CasperSearchRankingEnabled"
    )
}
