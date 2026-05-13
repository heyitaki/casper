// CASPER: Phase 0c step 12 follow-up. After dlopen of a NEW HMR dylib, copy
// HOST's runtime-patched Swift field-offset (`Wvd`) values into the NEW
// dylib's __DATA section. Without this, NEW.apply uses compile-time
// placeholder offsets that omit the ObjC superclass base size — e.g. for a
// CasperFindResultsView (NSScrollView subclass) the compile-time Wvd for
// `query` is 0x58 while the runtime value (after the Swift runtime patches
// class metadata at realization) is 0x58 + (sizeof(NSScrollView)-0x08) ≈
// 0x4E0. The runtime only patches HOST's Wvd table because the class is
// already registered when NEW is dlopen'd, so NEW's __DATA copy stays at the
// compile-time value. Calling NEW's swapped method body then reads/writes at
// the wrong instance offset and corrupts NSScrollView's ivars (manifests as
// EXC_BAD_ACCESS in `outlined assign with take of String`).
//
// Delete this file together with the rest of `Sources/Casper/HMR/` when
// upstream cmux ships an in-process HMR story.

#if DEBUG

import Darwin
import Foundation
import MachO

struct CasperHMRFieldOffsetPatchResult {
    let patched: Int
    let unchanged: Int
    let missing: Int
}

enum CasperHMRFieldOffsetPatcher {
    /// Walk the NEW dylib's symbol table for every `*Wvd` symbol, look up the
    /// matching symbol in a HOST image (skipping NEW and any prior HMR dylib),
    /// and copy HOST's runtime value into NEW's slot.
    static func patchFromHost(
        dylibPath: String,
        stateDirPrefix: String
    ) -> CasperHMRFieldOffsetPatchResult {
        let newIndex = findImage(matching: dylibPath)
        if newIndex < 0 {
            return CasperHMRFieldOffsetPatchResult(patched: 0, unchanged: 0, missing: 0)
        }

        // Collect every Wvd symbol exposed by HOST images (i.e. anything that
        // isn't the NEW dylib or a prior HMR dylib). HOST's Wvd values are the
        // ones the Swift runtime has already realised against the actual ObjC
        // superclass size, so they're what NEW.apply needs to read.
        var hostWvd: [String: UInt] = [:]
        let imageCount = _dyld_image_count()
        for idx in 0..<imageCount {
            guard let namePtr = _dyld_get_image_name(idx) else { continue }
            let imageName = String(cString: namePtr)
            if Int(idx) == newIndex { continue }
            if !stateDirPrefix.isEmpty && imageName.hasPrefix(stateDirPrefix) { continue }
            walkWvdSymbols(idx: Int(idx)) { name, addr in
                if hostWvd[name] == nil {
                    hostWvd[name] = UInt(bitPattern: Int(bitPattern: addr))
                }
            }
        }

        var patched = 0
        var unchanged = 0
        var missing = 0

        walkWvdSymbols(idx: newIndex) { name, newAddrRaw in
            guard let hostBits = hostWvd[name] else {
                missing += 1
                return
            }
            guard let hostPtr = UnsafePointer<UInt>(bitPattern: hostBits),
                  let newPtr = UnsafeMutablePointer<UInt>(
                      bitPattern: UInt(bitPattern: Int(bitPattern: newAddrRaw))
                  ) else {
                missing += 1
                return
            }
            let hostVal = hostPtr.pointee
            if newPtr.pointee == hostVal {
                unchanged += 1
            } else {
                newPtr.pointee = hostVal
                patched += 1
            }
        }

        return CasperHMRFieldOffsetPatchResult(
            patched: patched,
            unchanged: unchanged,
            missing: missing
        )
    }

    private static func findImage(matching path: String) -> Int {
        let imageCount = _dyld_image_count()
        for idx in 0..<imageCount {
            guard let namePtr = _dyld_get_image_name(idx) else { continue }
            if String(cString: namePtr) == path { return Int(idx) }
        }
        return -1
    }

    /// Invoke `callback(name, addr)` for every symbol ending in `Wvd` defined
    /// in the image at `idx`. `addr` is the runtime address of the 8-byte
    /// field-offset slot inside that image's __DATA section.
    private static func walkWvdSymbols(
        idx: Int,
        callback: (String, UnsafeRawPointer) -> Void
    ) {
        let idx32 = UInt32(idx)
        guard let headerRaw = _dyld_get_image_header(idx32) else { return }
        let slide = _dyld_get_image_vmaddr_slide(idx32)
        let headerPtr = UnsafeRawPointer(headerRaw)
            .assumingMemoryBound(to: mach_header_64.self)
        guard headerPtr.pointee.magic == MH_MAGIC_64 else { return }

        var cmdPtr = UnsafeRawPointer(headerPtr)
            .advanced(by: MemoryLayout<mach_header_64>.size)
        var symtab: UnsafePointer<symtab_command>? = nil
        var linkeditFileOff: UInt64 = 0
        var linkeditVmAddr: UInt64 = 0
        var foundLinkedit = false

        for _ in 0..<headerPtr.pointee.ncmds {
            let cmd = cmdPtr.assumingMemoryBound(to: load_command.self)
            switch cmd.pointee.cmd {
            case UInt32(LC_SYMTAB):
                symtab = cmdPtr.assumingMemoryBound(to: symtab_command.self)
            case UInt32(LC_SEGMENT_64):
                let seg = cmdPtr.assumingMemoryBound(to: segment_command_64.self)
                let segName = withUnsafeBytes(of: seg.pointee.segname) { raw -> String in
                    let bytes = raw.bindMemory(to: CChar.self)
                    return String(cString: bytes.baseAddress!)
                }
                if segName == "__LINKEDIT" {
                    linkeditFileOff = seg.pointee.fileoff
                    linkeditVmAddr = seg.pointee.vmaddr
                    foundLinkedit = true
                }
            default:
                break
            }
            cmdPtr = cmdPtr.advanced(by: Int(cmd.pointee.cmdsize))
        }

        guard let symtabPtr = symtab, foundLinkedit else { return }

        // __LINKEDIT's vmaddr/fileoff differ by the same constant for every
        // file-relative pointer inside it, so `linkeditSlide` converts a file
        // offset (like symtab.symoff) to a runtime address.
        let linkeditSlide = Int(linkeditVmAddr) - Int(linkeditFileOff) + slide
        let nlistBase = UInt(bitPattern: linkeditSlide + Int(symtabPtr.pointee.symoff))
        let strBase = UInt(bitPattern: linkeditSlide + Int(symtabPtr.pointee.stroff))
        guard let nlists = UnsafePointer<nlist_64>(bitPattern: nlistBase),
              let strings = UnsafePointer<CChar>(bitPattern: strBase) else { return }

        let nsyms = Int(symtabPtr.pointee.nsyms)
        for i in 0..<nsyms {
            let entry = nlists[i]
            let nType = entry.n_type
            // Skip debug stabs and undefined references; we only want defined
            // symbols sitting in a section (N_TYPE == N_SECT).
            if (nType & UInt8(N_STAB)) != 0 { continue }
            if (nType & UInt8(N_TYPE)) != UInt8(N_SECT) { continue }
            let strOff = Int(entry.n_un.n_strx)
            if strOff == 0 { continue }
            let namePtr = strings.advanced(by: strOff)
            // Suffix check directly on the C string avoids constructing
            // Strings for the ~30k symbols in a typical Swift module that
            // don't end in "Wvd".
            if !cStringHasSuffix(namePtr, suffix: "Wvd") { continue }
            let name = String(cString: namePtr)
            let runtimeAddr = UInt(bitPattern: Int(entry.n_value) + slide)
            guard let addr = UnsafeRawPointer(bitPattern: runtimeAddr) else { continue }
            callback(name, addr)
        }
    }

    private static func cStringHasSuffix(_ ptr: UnsafePointer<CChar>, suffix: StaticString) -> Bool {
        let len = strlen(ptr)
        let sufLen = suffix.utf8CodeUnitCount
        if Int(len) < sufLen { return false }
        return suffix.withUTF8Buffer { sufBuf -> Bool in
            let tail = ptr.advanced(by: Int(len) - sufLen)
            for i in 0..<sufLen {
                if UInt8(bitPattern: tail[i]) != sufBuf[i] { return false }
            }
            return true
        }
    }
}

#endif
