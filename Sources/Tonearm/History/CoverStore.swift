import CryptoKit
import Foundation

/// Covers the player downloaded for songs it recorded, kept beside the history database, so
/// Liner Notes can show them without asking the network again. One file per cover URL,
/// named by its SHA-256. Deleting the history deletes these too.
///
/// The player writes here only while Record listening is on, and only covers it fetched
/// anyway for the song playing. Liner Notes only reads.
final class CoverStore: @unchecked Sendable {
    /// Bigger than any cover Spotify reports (640 x 640 JPEG, about 100 KB).
    static let maxBytes = 2_000_000

    let directory: URL
    private let queue = DispatchQueue(label: "io.github.abulkosim.tonearm.covers", qos: .utility)

    init(directory: URL) {
        self.directory = directory
    }

    static func fileName(for url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func fileURL(for url: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: url))
    }

    /// Keeps `data` as the cover at `url`, unless one is already kept. Queued; failures are
    /// dropped, the window falls back to a drawn tile.
    func save(_ data: Data, for url: String) {
        guard !data.isEmpty, data.count <= Self.maxBytes else { return }
        queue.async { self.saveNow(data, for: url) }
    }

    func saveNow(_ data: Data, for url: String) {
        let file = fileURL(for: url)
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            NSLog("Tonearm: could not keep a cover: \(error)")
        }
    }

    /// The kept cover for `url`, or nil. Reads from disk only.
    func data(for url: String) async -> Data? {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: self.dataNow(for: url)) }
        }
    }

    func dataNow(for url: String) -> Data? {
        try? Data(contentsOf: fileURL(for: url))
    }

    /// Removes every kept cover.
    func deleteAllNow() throws {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            try FileManager.default.removeItem(at: directory)
        }
    }
}
