import CryptoKit
import Foundation

enum HaruGGUFInstaller {
    static let fileName = "Haru-4B-Q5_K.gguf"
    static let sourceBytes = 5_047_781_120
    private static let sha256 = "9b0f703a03c764d14a8e66ff8af1fa20a444d3cf2510c145288a5accf7d935ce"
    private static let source = URL(string:
        "https://huggingface.co/sakasegawa/Haru-4B-GGUF/resolve/fc026182f7bbfaa0400b2d44358a5e9e327b957f/Haru-4B-Q5_K.gguf")!
    static let directory = HaruModelInstaller.directory.appending(path: "GGUF", directoryHint: .isDirectory)
    static let installed = directory.appending(path: fileName)
    static let local = URL.documentsDirectory.appending(path: fileName)

    static var hasPartialDownload: Bool {
        FileManager.default.fileExists(atPath: partial(in: directory).path)
    }

    static var canResume: Bool {
        ((try? partial(in: directory).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }

    static func deletePartialDownload() throws {
        try FileManager.default.removeItem(at: partial(in: directory))
    }

    private static func partial(in root: URL) -> URL {
        root.appending(path: fileName + ".download")
    }

    static func size(of url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 24 else {
            throw HaruError.invalidPack("Haru-4BのGGUFファイルを選んでください")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.read(upToCount: 4) == Data("GGUF".utf8) else {
            throw HaruError.invalidPack("Haru-4BのGGUFファイルを選んでください")
        }
        return bytes
    }

    static func install(in root: URL, report: @Sendable (HaruModelInstaller.Progress) async -> Void) async throws -> URL {
        let files = FileManager.default
        let final = root.appending(path: fileName)
        if (try? size(of: final)) == sourceBytes { return final }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        var downloadRoot = root
        var backup = URLResourceValues()
        backup.isExcludedFromBackup = true
        try downloadRoot.setResourceValues(backup)

        let temporary = partial(in: root)
        if !files.fileExists(atPath: temporary.path) {
            try Data().write(to: temporary, options: .withoutOverwriting)
        }
        let handle = try FileHandle(forUpdating: temporary)
        defer { try? handle.close() }
        var written = Int(try handle.seekToEnd())
        if written > sourceBytes {
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            written = 0
        }
        let remaining = sourceBytes - written
        if let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           free < remaining {
            let size = ByteCountFormatter.string(fromByteCount: Int64(remaining), countStyle: .file)
            throw HaruError.invalidPack("あと約\(size)を保存できる空き容量を確保してください")
        }

        while written < sourceBytes {
            try Task.checkCancellation()
            let end = min(written + 64 * 1024 * 1024, sourceBytes)
            let chunk = try await HaruCheckpointRange.fetch(source, bytes: written..<end,
                                                            totalBytes: sourceBytes, report: report)
            try handle.write(contentsOf: chunk)
            written = end
        }
        try handle.synchronize()
        await report(.init(sourceBytesRead: sourceBytes, phase: .checking))
        guard try await checksum(of: temporary) == sha256 else {
            try files.removeItem(at: temporary)
            throw HaruError.invalidPack("GGUFのチェックサムが一致しません。ダウンロードし直してください")
        }
        try Task.checkCancellation()
        if files.fileExists(atPath: final.path) { try files.removeItem(at: final) }
        try files.moveItem(at: temporary, to: final)
        return final
    }

    @concurrent
    private static func checksum(of file: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let hasMoreData = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else {
                    return false
                }
                hash.update(data: chunk)
                return true
            }
            if !hasMoreData { break }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
