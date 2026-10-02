import Foundation

public enum LogRotation {
    public static let defaultLimit: UInt64 = 5 * 1024 * 1024

    /// Keep the newest segment in one archive, then truncate the active inode.
    /// The child keeps its O_APPEND descriptor open across rotation.
    public static func rotateIfNeeded(at url: URL, limit: UInt64 = defaultLimit) throws {
        precondition(limit > 0 && limit <= UInt64(Int.max))
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= limit else { return }
        try handle.seek(toOffset: size - limit)
        let tail = try handle.read(upToCount: Int(limit)) ?? Data()
        let archive = url.appendingPathExtension("1")
        try tail.write(to: archive, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        // Copy/truncate is best-effort: bytes appended during the copy can be lost.
        try handle.truncate(atOffset: 0)
    }
}
