import Foundation

/// Appends to a capped log, trimming to a line-aligned tail in place so `tail -f` keeps following it.
public enum CappedLogWriter {
    public static let defaultMaxBytes: Int = 256 * 1024 * 1024

    public static func resolvedMaxBytes(environment: [String: String]) -> Int {
        let bytesPerMegabyte = 1024 * 1024
        guard
            let value = environment["CMUX_DEBUG_LOG_MAX_MB"],
            let megabytes = Int(value),
            megabytes >= 1
        else {
            return defaultMaxBytes
        }

        let (bytes, overflow) = megabytes.multipliedReportingOverflow(by: bytesPerMegabyte)
        return overflow ? defaultMaxBytes : bytes
    }

    public static func tailKeepBytes(forMaxBytes maxBytes: Int) -> Int {
        let megabyte = 1024 * 1024
        return max(megabyte, min(64 * megabyte, maxBytes / 4))
    }

    public static let processMaxBytes = resolvedMaxBytes(environment: ProcessInfo.processInfo.environment)
    public static let processTailKeepBytes = tailKeepBytes(forMaxBytes: processMaxBytes)

    public static func append(_ data: Data, toFileAtPath path: String) {
        append(data, toFileAtPath: path, maxBytes: processMaxBytes, tailKeepBytes: processTailKeepBytes)
    }

    public static func append(
        _ data: Data,
        toFileAtPath path: String,
        maxBytes: Int,
        tailKeepBytes: Int
    ) {
        let url = URL(fileURLWithPath: path)
        let handle: FileHandle
        if let opened = try? FileHandle(forUpdating: url) {
            handle = opened
        } else {
            FileManager.default.createFile(atPath: path, contents: nil)
            guard let created = try? FileHandle(forUpdating: url) else { return }
            handle = created
        }
        defer { try? handle.close() }

        do {
            let oldSize = try handle.seekToEnd()
            let cappedSize = UInt64(max(0, maxBytes))
            let appendSize = UInt64(data.count)
            if oldSize <= cappedSize, appendSize <= cappedSize - oldSize {
                try handle.write(contentsOf: data)
                return
            }

            let tailSize = min(UInt64(max(0, tailKeepBytes)), oldSize)
            try handle.seek(toOffset: oldSize - tailSize)
            var tail = try handle.read(upToCount: Int(tailSize)) ?? Data()
            if let newline = tail.firstIndex(of: 0x0A) {
                tail = Data(tail[tail.index(after: newline)...])
            }

            // Write over the head before truncating so a mid-trim failure can't destroy the retained tail.
            try handle.seek(toOffset: 0)
            let marker = "--- cmux debug log auto-trimmed from \(oldSize) bytes ---\n"
            let markerData = Data(marker.utf8)
            try handle.write(contentsOf: markerData)
            try handle.write(contentsOf: tail)
            try handle.write(contentsOf: data)
            let newSize = UInt64(markerData.count + tail.count + data.count)
            try handle.truncate(atOffset: newSize)
        } catch {
            return
        }
    }
}
