// CASPER: Sub-100µs pre-compile triage of Casper source diffs (Req 21).
// Catches edit classes the dylib interpose mechanism cannot reliably swap
// (added stored properties, new enum cases, new conformances, etc.) and
// short-circuits the pipeline with result=out_of_envelope_predicted so the
// user sees the "needs reload.sh" signal in <1ms instead of waiting 800ms for
// a compile that lands as no_interpose anyway.
//
// Regex-based, not AST-based — keeping a Swift-frontend dependency off the
// hot path is the whole point. False positives are acceptable; the cost is
// one unneeded reload.sh. Phase 0c step 14b tunes the regex set against
// real Casper diffs.

#if DEBUG

import Foundation

struct CasperHMRClassifierResult {
    enum Kind {
        /// Diff classifies as body-only or whitespace-only. Safe to compile.
        case bodyLikely
        /// Diff hits one of the out-of-envelope patterns; recommend reload.sh.
        case outOfEnvelope
    }

    let kind: Kind
    /// Token that triggered the prediction (e.g. "stored_property", "import").
    /// nil for bodyLikely.
    let reason: String?
}

enum CasperHMRSourceClassifier {
    /// Classify a diff between `before` and `after` bytes. Pure function;
    /// expected sub-100µs for realistic file sizes.
    static func classify(beforeBytes: Data, afterBytes: Data) -> CasperHMRClassifierResult {
        guard let beforeStr = String(data: beforeBytes, encoding: .utf8),
              let afterStr = String(data: afterBytes, encoding: .utf8) else {
            // Binary or invalid UTF-8 — be conservative and treat as bodyLikely;
            // the compile step will catch real problems.
            return CasperHMRClassifierResult(kind: .bodyLikely, reason: nil)
        }

        if beforeStr == afterStr {
            return CasperHMRClassifierResult(kind: .bodyLikely, reason: nil)
        }

        let beforeLines = Set(beforeStr.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        let afterLines = Set(afterStr.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))

        let added = afterLines.subtracting(beforeLines)
        let removed = beforeLines.subtracting(afterLines)

        for line in added.union(removed) {
            if let reason = matchOutOfEnvelopeToken(line) {
                return CasperHMRClassifierResult(kind: .outOfEnvelope, reason: reason)
            }
        }

        return CasperHMRClassifierResult(kind: .bodyLikely, reason: nil)
    }

    /// Whole-line patterns that historically correlate with edits the dylib
    /// interpose mechanism can't reliably swap. Returns the matching token
    /// name (used in result.reason and surfaced in the Recent Swaps panel).
    private static func matchOutOfEnvelopeToken(_ rawLine: String) -> String? {
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard !line.isEmpty else { return nil }

        // `import ` at column 0 — module graph change.
        if rawLine.hasPrefix("import ") {
            return "import"
        }

        // New type at line start.
        for keyword in ["class ", "struct ", "enum ", "actor ", "protocol "] {
            if line.hasPrefix(keyword) {
                return "type_decl"
            }
        }

        // New conformance: `extension Foo: Bar { ... }`. Match the conformance
        // colon to avoid flagging method-bearing extensions.
        if line.hasPrefix("extension ") && line.range(of: #"extension\s+\w+\s*:\s*\w"#, options: .regularExpression) != nil {
            return "conformance"
        }

        // Stored property: `var foo: Bar` / `let foo: Bar` at type-body indent
        // (any indentation, but stripped of leading whitespace above). We can't
        // tell type-body from local-let with a regex alone; the daemon falls
        // back to compile if this is a local-let. False positives are tolerable
        // here per Req 21.
        if line.hasPrefix("var ") || line.hasPrefix("let ") {
            // Heuristic: stored-property-style declarations usually have an
            // explicit type annotation or property attribute. `let x = 1`
            // inside a function body is the dominant FP class — but the line
            // starts with `let ` after trim, same as `let foo: Bar` at type
            // scope, so we can't distinguish. Default to flagging only when
            // the line has `:` (type annotation) or `@` attribute — gates out
            // the most common FP without missing real stored-property diffs.
            if line.contains(":") || line.contains("@") {
                return "stored_property"
            }
        }

        // New enum case at type-body indent.
        if line.hasPrefix("case ") {
            return "enum_case"
        }

        // Attribute-driven dispatch changes.
        let attributeMarkers = [
            "@inlinable",
            "@_transparent",
            "@frozen",
            "@objc(",
            "@dynamicCallable",
            "@dynamicMemberLookup",
        ]
        for marker in attributeMarkers where line.contains(marker) {
            return "attribute_\(marker.replacingOccurrences(of: "@", with: ""))"
        }

        if line.hasPrefix("dynamic func ") {
            return "dynamic_func"
        }

        // Actor-isolation changes — alter generated thunks in ways the
        // interpose section may not redirect cleanly.
        for marker in ["@MainActor", "nonisolated", "isolated "] where line.contains(marker) {
            return "actor_isolation"
        }

        return nil
    }
}

#endif
