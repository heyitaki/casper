// CASPER: fishhook-based live symbol rebinding (Phase 0c step 12). After a
// successful `dlopen`, this scans the new dylib's exported "injectable" Swift
// symbols, dlsym's them to get the new addresses, and walks every loaded
// image to rewrite `__got` / `__la_symbol_ptr` entries via fishhook's
// `rebind_symbols_image`. With the host built with `-Xlinker -interposable`,
// intra-host calls also go through stub tables, so this catches calls inside
// the cmux module to its own functions.
//
// Pure-Swift dylibs don't emit `__DATA[_CONST],__interpose` sections, so the
// dyld static-interpose path the spec assumed doesn't fire for our compile
// pipeline. This file is the runtime equivalent that InjectionLite/DLKit use
// to achieve the same swap behavior. Delete the file together with the rest
// of `Sources/Casper/HMR/` when upstream cmux ships an in-process HMR story.

#if DEBUG

import Darwin
import Foundation
import MachO

/// Swift mirror of fishhook's `struct rebinding`. Layout-compatible with the C
/// definition in `fishhookD/fishhook.h`. We declare it here to avoid taking a
/// direct `import fishhookD` module dependency — the underlying C symbols come
/// in transitively via the InjectionLite SPM dep. After PR 3 deletes that dep,
/// fishhookD should be re-introduced as a direct cmux dependency.
struct CasperHMRRebinding {
    var name: UnsafePointer<CChar>?
    var replacement: UnsafeMutableRawPointer?
    var replaced: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
}

@_silgen_name("rebind_symbols_image")
private func _casper_rebind_symbols_image(
    _ header: UnsafeMutableRawPointer?,
    _ slide: Int,
    _ rebindings: UnsafeMutablePointer<CasperHMRRebinding>,
    _ count: Int
) -> Int32

struct CasperHMRInterposeResult {
    let result: String
    let entryCount: Int
    let matchedSymbols: [String]
    let reason: String?
}

enum CasperHMRInterposer {
    /// Rebind every loaded image's GOT/la_symbol_ptr entries that reference
    /// any of the dylib's injectable Swift exports.
    ///
    /// - Parameters:
    ///   - dylibHandle: the `dlopen` return value for the new dylib.
    ///   - dylibPath: filesystem path of the loaded dylib (for `nm -gU`).
    ///   - stateDirPrefix: dylibs whose path starts with this prefix are
    ///     skipped when walking images — avoids touching our own
    ///     previously-loaded HMR dylibs.
    ///   - symbolSet: pre-extracted mangled-symbol set for the changed source
    ///     file (per Req 9). Used to validate that ≥1 swap targets a symbol
    ///     declared in the saved file. Pass `nil` if the `.o` was missing.
    static func rebindAllImages(
        dylibHandle: UnsafeMutableRawPointer,
        dylibPath: String,
        stateDirPrefix: String,
        symbolSet: Set<String>?
    ) -> CasperHMRInterposeResult {
        let exports = readDylibExports(dylibPath: dylibPath)
        let injectables = exports.filter { isInjectableSwiftSymbol($0) }
        if injectables.isEmpty {
            return CasperHMRInterposeResult(
                result: "no_interpose",
                entryCount: 0,
                matchedSymbols: [],
                reason: nil
            )
        }

        // Resolve new addresses in the loaded dylib. dlsym takes the symbol
        // without the leading `_`. CRITICAL: fishhook unconditionally writes
        // `rebindings[i].replacement` into the matched GOT slot, with no
        // NULL check (fishhook.c:139). If `dlsym` fails for any symbol and
        // we leave it in the list, fishhook nulls out that GOT entry across
        // every image — the next call through it traps. So we filter out
        // any unresolved symbols before building rebindings.
        // `name` is the underscore-stripped form (what fishhook compares
        // against). `original` is the `_`-prefixed form from `nm -gU` (what
        // we use for the cross-reference against `symbolSet`, which also
        // came from `nm -gU`).
        var resolved: [(name: String, original: String, addr: UnsafeMutableRawPointer)] = []
        resolved.reserveCapacity(injectables.count)
        for symbol in injectables {
            let stripped = symbol.hasPrefix("_") ? String(symbol.dropFirst()) : symbol
            if let addr = stripped.withCString({ dlsym(dylibHandle, $0) }) {
                resolved.append((name: stripped, original: symbol, addr: addr))
            }
        }
        if resolved.isEmpty {
            return CasperHMRInterposeResult(
                result: "no_interpose",
                entryCount: 0,
                matchedSymbols: [],
                reason: "dlsym_all_failed"
            )
        }

        // Persistent C-string buffers for the rebind name pointers. These
        // must outlive every `rebind_symbols_image` call across all images.
        // fishhook compares `strcmp(&symbol_name[1], rebindings[i].name)` —
        // i.e. it strips the leading `_` from the symbol-table entry and
        // expects `rebindings[i].name` to NOT have one. We stored the
        // stripped form above.
        let nameBuffers: [UnsafeMutablePointer<CChar>] = resolved.map { entry in
            let utf8 = Array(entry.name.utf8)
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count + 1)
            for (i, byte) in utf8.enumerated() {
                buf[i] = CChar(bitPattern: byte)
            }
            buf[utf8.count] = 0
            return buf
        }
        defer { nameBuffers.forEach { $0.deallocate() } }

        // Per-symbol "previous value" slot. Fishhook writes the prior pointer
        // into this slot when it actually replaces a GOT entry. We zero it
        // before each `rebind_symbols_image` call so a non-nil value after
        // proves the entry was replaced in that image. Across images, we OR
        // into `anyReplaced` so the final set is the union over all images.
        let count = resolved.count
        let replacedSlots = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: count)
        defer { replacedSlots.deallocate() }

        var rebindings: [CasperHMRRebinding] = []
        rebindings.reserveCapacity(count)
        for i in 0..<count {
            rebindings.append(CasperHMRRebinding(
                name: UnsafePointer(nameBuffers[i]),
                replacement: resolved[i].addr,
                replaced: replacedSlots.advanced(by: i)
            ))
        }

        var anyReplaced: Set<String> = []
        let imageCount = _dyld_image_count()
        for idx in 0..<imageCount {
            guard let namePtr = _dyld_get_image_name(idx) else { continue }
            let imageName = String(cString: namePtr)
            // Skip our own previously-loaded HMR dylibs to avoid rebinding
            // into a stale earlier swap of the same source file.
            if !stateDirPrefix.isEmpty && imageName.hasPrefix(stateDirPrefix) { continue }
            // Skip the just-loaded dylib itself.
            if imageName == dylibPath { continue }
            // Reset slots before each image-level rebind.
            for i in 0..<count { replacedSlots[i] = nil }
            // Refresh `replaced` field on each rebinding entry in case the
            // pointer needs to be re-seated (defensive — the address is the
            // same offset into the buffer).
            for i in 0..<count {
                rebindings[i].replaced = replacedSlots.advanced(by: i)
            }
            let header = UnsafeMutableRawPointer(mutating: _dyld_get_image_header(idx))
            let slide = _dyld_get_image_vmaddr_slide(idx)
            _ = rebindings.withUnsafeMutableBufferPointer { buf -> Int32 in
                guard let base = buf.baseAddress else { return -1 }
                return _casper_rebind_symbols_image(header, slide, base, count)
            }
            for i in 0..<count where replacedSlots[i] != nil {
                anyReplaced.insert(resolved[i].original)
            }
        }

        if anyReplaced.isEmpty {
            return CasperHMRInterposeResult(
                result: "no_interpose_for_file",
                entryCount: count,
                matchedSymbols: [],
                reason: nil
            )
        }

        if let symbolSet, !symbolSet.isEmpty {
            let intersect = anyReplaced.intersection(symbolSet)
            if !intersect.isEmpty {
                return CasperHMRInterposeResult(
                    result: "ok",
                    entryCount: count,
                    matchedSymbols: Array(intersect),
                    reason: nil
                )
            }
            return CasperHMRInterposeResult(
                result: "no_interpose_for_file",
                entryCount: count,
                matchedSymbols: [],
                reason: nil
            )
        }
        return CasperHMRInterposeResult(
            result: "ok_unverified",
            entryCount: count,
            matchedSymbols: Array(anyReplaced),
            reason: "missing_object_file"
        )
    }

    private static func readDylibExports(dylibPath: String) -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        proc.arguments = ["-gU", dylibPath]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [String] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard let last = parts.last else { continue }
            let str = String(last)
            if str.hasPrefix("_") { result.append(str) }
        }
        return result
    }

    /// Subset of InjectionLite's `injectableSymbol` predicate (Reloader.swift
    /// :361). Accepts Swift function bodies (F/g/s/C/Df suffixes) and skips
    /// type metadata / witness tables / property descriptors. C++ mangled
    /// names (`_ZN…`) are also accepted to mirror InjectionLite's behavior.
    static func isInjectableSwiftSymbol(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count >= 4 else { return false }
        let start = bytes[0] == UInt8(ascii: "_") ? 1 : 0
        guard bytes.count - start >= 3 else { return false }
        // C++ mangled: _ZN…
        if bytes[start] == UInt8(ascii: "_") &&
           bytes[start + 1] == UInt8(ascii: "Z") &&
           bytes[start + 2] == UInt8(ascii: "N") {
            return true
        }
        // Swift mangled: $s prefix, but skip stdlib ($sS… / $ss…).
        guard bytes[start] == UInt8(ascii: "$"),
              bytes[start + 1] == UInt8(ascii: "s") else {
            return false
        }
        let third = bytes[start + 2]
        if third == UInt8(ascii: "S") || third == UInt8(ascii: "s") { return false }

        let lastIdx = bytes.count - 1
        let last = bytes[lastIdx]
        let prev = lastIdx >= 1 ? bytes[lastIdx - 1] : 0

        // Init suffix: ...C
        if last == UInt8(ascii: "C") { return true }
        // Destructor suffix: ...Df
        if last == UInt8(ascii: "f") && prev == UInt8(ascii: "D") { return true }
        // Getter/setter suffix: ...g / ...s
        if last == UInt8(ascii: "g") || last == UInt8(ascii: "s") { return true }
        // Function suffix: ...F, but not ...MF (method descriptor) and not ...QF
        if last == UInt8(ascii: "F") {
            if prev == UInt8(ascii: "M") || prev == UInt8(ascii: "Q") { return false }
            return true
        }
        return false
    }
}

#endif
