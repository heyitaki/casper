// CASPER: Shared env > Info.plist > brand-name fallback flag resolver used by every Casper feature gate.

import Foundation

enum CasperBuildEnvironment {
    static let isBranded: Bool = {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        return name?.lowercased().contains("casper") == true
    }()

    /// Resolves a flag once on first access and caches it. Env vars and Info.plist
    /// are fixed for the life of the process, so re-reading them on every hot-path
    /// call is wasted work.
    static func flag(envKey: String, plistKey: String) -> Bool {
        if let raw = ProcessInfo.processInfo.environment[envKey] {
            return parseBool(raw)
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: plistKey) {
            if let bool = value as? Bool { return bool }
            if let number = value as? NSNumber { return number.boolValue }
            if let string = value as? String { return parseBool(string) }
        }
        return isBranded
    }

    static func parseBool(_ raw: String) -> Bool {
        switch raw.lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        default:
            return false
        }
    }
}
