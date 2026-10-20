import Darwin
import Foundation

/// Writes a complete, flushed file off the main actor, then publishes it in one filesystem operation.
/// Direct exports use exclusive rename, never hard links or a check-then-overwrite sequence.
enum AtomicPNGWriter {
    /// Publication hooks are worker-thread test seams, not UI callbacks.
    static func write(_ data: Data, directory: URL, filename: String,
                      beforePublication: @escaping @Sendable (URL) throws -> Void = { _ in },
                      afterPublication: @escaping @Sendable (URL) -> Void = { _ in }) async throws -> URL {
        try await perform(data, directory: directory, filename: filename, replaceExisting: false,
                          beforePublication: beforePublication, afterPublication: afterPublication)
    }

    /// Only for a destination whose replacement has already been confirmed by NSSavePanel.
    static func replace(_ data: Data, at url: URL) async throws -> URL {
        guard url.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        return try await perform(data, directory: url.deletingLastPathComponent(),
                                 filename: url.lastPathComponent, replaceExisting: true,
                                 beforePublication: { _ in }, afterPublication: { _ in })
    }

    /// Serialize cancellation with the irreversible syscall: cancellation that wins the lock
    /// prevents publication; cancellation after publication must still return the file receipt.
    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        func check() throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
        }

        func publish(_ body: () -> Int32) throws -> (result: Int32, error: Int32) {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            let result = body()
            return (result, errno)
        }
    }

    private static func perform(_ data: Data, directory: URL, filename: String,
                                replaceExisting: Bool,
                                beforePublication: @escaping @Sendable (URL) throws -> Void,
                                afterPublication: @escaping @Sendable (URL) -> Void) async throws -> URL {
        let cancellation = CancellationState()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .utility) {
                try writeSynchronously(data, directory: directory, filename: filename,
                                       replaceExisting: replaceExisting, cancellation: cancellation,
                                       beforePublication: beforePublication, afterPublication: afterPublication)
            }.value
        }, onCancel: { cancellation.cancel() })
    }

    private static func writeSynchronously(_ data: Data, directory: URL, filename: String,
                                           replaceExisting: Bool, cancellation: CancellationState,
                                           beforePublication: @Sendable (URL) throws -> Void,
                                           afterPublication: @Sendable (URL) -> Void) throws -> URL {
        try cancellation.check()
        try ImageSaveDirectoryError.validate(directory)
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        let directoryFD = directory.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) } ?? -1
        }
        guard directoryFD >= 0 else { throw posixError(at: directory) }
        defer { Darwin.close(directoryFD) }

        // O_EXCL makes this temporary file ours alone; no existing file is ever removed on failure.
        var temporaryName: String
        var temporaryFD: Int32
        repeat {
            try cancellation.check()
            temporaryName = ".iclipboard-\(UUID().uuidString).tmp"
            temporaryFD = Darwin.openat(directoryFD, temporaryName,
                                        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        } while temporaryFD < 0 && errno == EEXIST
        guard temporaryFD >= 0 else { throw posixError(at: directory) }
        var temporaryExists = true
        defer {
            Darwin.close(temporaryFD)
            // Successful rename consumes the private name; never remove the published output.
            if temporaryExists { Darwin.unlinkat(directoryFD, temporaryName, 0) }
        }

        let temporaryURL = directory.appendingPathComponent(temporaryName)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try cancellation.check()
                let count = Darwin.write(temporaryFD, bytes.baseAddress!.advanced(by: offset),
                                         min(bytes.count - offset, 1_048_576))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError(at: temporaryURL)
                }
                guard count > 0 else { throw posixError(at: temporaryURL, code: EIO) }
                offset += count
            }
        }
        while Darwin.fsync(temporaryFD) != 0 {
            if errno == EINTR {
                try cancellation.check()
                continue
            }
            throw posixError(at: temporaryURL)
        }
        try beforePublication(temporaryURL)

        let stem = (filename as NSString).deletingPathExtension
        let pathExtension = (filename as NSString).pathExtension
        var candidate = filename
        var suffix = 2
        while true {
            try cancellation.check()
            let outputURL = directory.appendingPathComponent(candidate)
            let publication = try cancellation.publish {
                if replaceExisting {
                    return Darwin.renameat(directoryFD, temporaryName, directoryFD, candidate)
                }
                // RENAME_EXCL atomically rejects collisions without requiring hard-link
                // support on the destination volume. Never fall back to replacing rename.
                return Darwin.renameatx_np(directoryFD, temporaryName, directoryFD, candidate, UInt32(RENAME_EXCL))
            }
            if publication.result == 0 {
                temporaryExists = false
                afterPublication(outputURL)
                return outputURL
            }
            guard !replaceExisting, publication.error == EEXIST else {
                throw posixError(at: outputURL, code: publication.error)
            }
            candidate = "\(stem)_\(suffix)" + (pathExtension.isEmpty ? "" : ".\(pathExtension)")
            suffix += 1
        }
    }

    private static func posixError(at url: URL, code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
