import Darwin
import Foundation

struct CmuxTopProcessArguments: Sendable {
    let arguments: [String]
    let environment: [String: String]
}

extension CmuxTopProcessSnapshot {
    static func processArgumentsAndEnvironment(for pid: Int) -> CmuxTopProcessArguments? {
        guard pid > 0, pid <= Int(Int32.max),
              let bytes = kernProcArgsBytes(for: pid) else {
            return nil
        }
        return processArgumentsAndEnvironment(fromKernProcArgs: bytes)
    }

    static func processArgumentsAndEnvironment(fromKernProcArgs bytes: [UInt8]) -> CmuxTopProcessArguments? {
        // CASPER: in Debug builds, walking `bytes[i]` per byte over a 4 KB–1 MB
        // argv+env buffer pays the Array bounds-check overhead on every
        // subscript (visible as `_swift_isClassOrObjCExistentialType` in
        // samples), making a single heavy autosave scan over ~70 cmux-scoped
        // processes burn seconds of CPU. Delete if upstream rewrites argv
        // capture to use libproc directly.
        bytes.withUnsafeBufferPointer { Self.parseKernProcArgs(buffer: $0) }
    }

    private static func parseKernProcArgs(buffer: UnsafeBufferPointer<UInt8>) -> CmuxTopProcessArguments? {
        let argcSize = MemoryLayout<Int32>.size
        guard buffer.count > argcSize, let base = buffer.baseAddress else { return nil }

        var argcRaw: Int32 = 0
        withUnsafeMutableBytes(of: &argcRaw) { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(start: base, count: argcSize))
        }
        let argc = Int(Int32(littleEndian: argcRaw))
        guard argc > 0 else { return nil }

        let count = buffer.count
        var index = argcSize
        // KERN_PROCARGS2 layout: argc (Int32), exec_path (NUL-padded), then
        // argv strings, then env strings. Skip the leading exec path + its
        // NUL padding before reading the argv block.
        while index < count, base[index] != 0 { index += 1 }
        while index < count, base[index] == 0 { index += 1 }

        var arguments: [String] = []
        arguments.reserveCapacity(argc)
        for _ in 0..<argc {
            guard index < count else { return nil }
            let start = index
            while index < count, base[index] != 0 { index += 1 }
            if start < index {
                let slice = UnsafeBufferPointer(start: base + start, count: index - start)
                arguments.append(String(decoding: slice, as: UTF8.self))
            }
            while index < count, base[index] == 0 { index += 1 }
        }

        var environment: [String: String] = [:]
        while index < count {
            while index < count, base[index] == 0 { index += 1 }
            guard index < count else { break }
            let start = index
            while index < count, base[index] != 0 { index += 1 }
            // skipNulls + skipString together always advance index unless
            // we're at end-of-buffer, so `start < index` is guaranteed here.
            let length = index - start
            guard let equalsOffset = (0..<length).first(where: { base[start + $0] == UInt8(ascii: "=") }),
                  equalsOffset > 0 else { continue }
            let keySlice = UnsafeBufferPointer(start: base + start, count: equalsOffset)
            let valueStart = start + equalsOffset + 1
            let valueLen = length - equalsOffset - 1
            let valueSlice = UnsafeBufferPointer(start: base + valueStart, count: valueLen)
            let key = String(decoding: keySlice, as: UTF8.self)
            environment[key] = String(decoding: valueSlice, as: UTF8.self)
        }

        return CmuxTopProcessArguments(arguments: arguments, environment: environment)
    }

    private static func kernProcArgsBytes(for pid: Int) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size: size_t = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        let success = buffer.withUnsafeMutableBytes { rawBuffer in
            sysctl(&mib, u_int(mib.count), rawBuffer.baseAddress, &size, nil, 0) == 0
        }
        guard success else { return nil }
        if size < buffer.count {
            buffer.removeLast(buffer.count - Int(size))
        }
        return buffer
    }
}
