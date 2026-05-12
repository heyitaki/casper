// CASPER: Flag gate (env > Info.plist > brand-name fallback) for the CodeEditSourceEditor text branch in FilePreviewPanel.

import Foundation

enum CasperEditorConfig {
    static var useCodeEditorInFilePreview: Bool {
        if let raw = ProcessInfo.processInfo.environment["CMUX_CASPER_EDITOR"] {
            return parseBool(raw)
        }
        if let plistValue = Bundle.main.object(forInfoDictionaryKey: "CasperEditorEnabled") {
            if let bool = plistValue as? Bool { return bool }
            if let number = plistValue as? NSNumber { return number.boolValue }
            if let string = plistValue as? String { return parseBool(string) }
        }
        return isCasperBrandedBuild
    }

    private static var isCasperBrandedBuild: Bool {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        return name?.lowercased().contains("casper") == true
    }

    private static func parseBool(_ raw: String) -> Bool {
        switch raw.lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        default:
            return false
        }
    }
}
