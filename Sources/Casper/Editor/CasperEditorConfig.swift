// CASPER: Flag gate (env > Info.plist > brand-name fallback) for the CodeEditSourceEditor text branch in FilePreviewPanel.

import Foundation

enum CasperEditorConfig {
    static let useCodeEditorInFilePreview: Bool = CasperBuildEnvironment.flag(
        envKey: "CMUX_CASPER_EDITOR",
        plistKey: "CasperEditorEnabled"
    )
}
