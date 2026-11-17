import AppKit
import UniformTypeIdentifiers

/// State behind Settings > History: what is stored, and import, export and delete.
///
/// It lives outside the view: the open and save panels close the menu bar window, and an
/// import goes on after that. Open the window again and the progress or result is there.
@MainActor
final class HistorySettingsModel: ObservableObject {
    static let shared = HistorySettingsModel(store: HistoryStore.shared)

    enum Action: Equatable {
        case imported, exported, deleted
    }

    /// The result of the last import, export or delete, shown under its row.
    struct Note: Equatable {
        var action: Action
        var text: String
        var isError = false
        /// A file to show in Finder.
        var file: URL?
    }

    @Published private(set) var summary: HistorySummary?
    @Published private(set) var isImporting = false
    @Published private(set) var progress: ImportProgress?
    @Published private(set) var isBusy = false
    @Published private(set) var note: Note?
    @Published var confirmingDelete = false

    private let store: HistoryStore?
    /// Where the history is, for the privacy line.
    let folder: URL

    init(store: HistoryStore?) {
        self.store = store
        folder = (store?.url ?? HistoryStore.defaultURL).deletingLastPathComponent()
    }

    /// For snapshots: fixed state, never reads the disk.
    static func preview(summary: HistorySummary?, importing: ImportProgress? = nil, note: Note? = nil,
                        confirmingDelete: Bool = false) -> HistorySettingsModel {
        let model = HistorySettingsModel(store: nil)
        model.summary = summary
        model.isImporting = importing != nil
        model.progress = importing
        model.note = note
        model.confirmingDelete = confirmingDelete
        return model
    }

    /// The sample the settings snapshots show.
    static var sample: HistorySettingsModel {
        preview(summary: HistorySummary(count: 48_872, first: Self.date(2019, 3, 4), last: Self.date(2026, 11, 16)))
    }

    var displayFolder: String { (folder.path as NSString).abbreviatingWithTildeInPath }

    func refresh() {
        guard let store else { return }
        Task {
            do {
                summary = try await store.summary()
            } catch {
                summary = nil
                note = Note(action: .imported, text: "Can't read the history: \(error)", isError: true)
            }
        }
    }

    // MARK: Import

    func chooseImport() {
        guard !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Spotify Data"
        panel.message = "Choose the .zip or folder from Spotify's data download, or its StreamingHistory files."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip, .json]
        Onboarding.activate()
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in await self?.runImport(urls) }
        }
    }

    func runImport(_ urls: [URL]) async {
        guard let store, !isImporting, !isBusy else { return }
        isImporting = true
        confirmingDelete = false
        progress = nil
        note = nil
        do {
            let result = try await store.import(urls: urls) { p in
                // On the store's queue.
                Task { @MainActor [weak self] in
                    if self?.isImporting == true { self?.progress = p }
                }
            }
            note = Note(action: .imported, text: Self.describe(result))
        } catch {
            note = Note(action: .imported, text: "\(error)", isError: true)
        }
        isImporting = false
        progress = nil
        refresh()
    }

    static func describe(_ r: ImportResult) -> String {
        var parts: [String] = []
        if r.added == 0 {
            parts.append(r.duplicates > 0 ? "Nothing new: all \(count(r.duplicates)) were already here."
                         : "No listens in those files.")
        } else {
            var line = "Added \(count(r.added)) \(r.added == 1 ? "listen" : "listens")"
            if let first = r.first, let last = r.last {
                let a = monthYear(first), b = monthYear(last)
                line += a == b ? " from \(a)" : " from \(a) to \(b)"
            }
            parts.append(line + ".")
            if r.duplicates > 0 { parts.append("\(count(r.duplicates)) were already here.") }
        }
        if !r.unreadable.isEmpty {
            parts.append(r.unreadable.count == 1 ? "1 file could not be read." : "\(r.unreadable.count) files could not be read.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Export

    func chooseExport(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.title = "Export Listening History"
        panel.nameFieldStringValue = "Tonearm listens \(Self.day(Date())).\(format.rawValue)"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.canCreateDirectories = true
        Onboarding.activate()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.export(to: url, format: format) }
        }
    }

    func export(to url: URL, format: ExportFormat) async {
        guard let store, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let n = try await store.export(to: url, format: format)
            note = Note(action: .exported,
                        text: "Saved \(Self.count(n)) \(n == 1 ? "listen" : "listens") to \(url.lastPathComponent).",
                        file: url)
        } catch {
            note = Note(action: .exported, text: "Could not save: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: Delete

    /// Not while an import runs: the delete would wait behind it and the count would be old.
    func deleteAll(listenBrainz: ListenBrainzSync) async {
        guard let store, !isBusy, !isImporting else { return }
        isBusy = true
        defer {
            isBusy = false
            confirmingDelete = false
        }
        let n = summary?.count ?? 0
        do {
            try await store.deleteAll()
            listenBrainz.deleteQueued()
            note = Note(action: .deleted, text: "Deleted \(Self.count(n)) \(n == 1 ? "listen" : "listens").")
        } catch {
            note = Note(action: .deleted, text: "Could not delete: \(error)", isError: true)
        }
        refresh()
    }

    // MARK: Finder

    func showInFinder(_ file: URL? = nil) {
        if let file {
            NSWorkspace.shared.activateFileViewerSelecting([file])
            return
        }
        let db = store?.url ?? HistoryStore.defaultURL
        if FileManager.default.fileExists(atPath: db.path) {
            NSWorkspace.shared.activateFileViewerSelecting([db])
        } else {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    // MARK: Words

    /// "48,872 listens since March 2019".
    func summaryLine(recording: Bool) -> String {
        guard let summary else { return " " }
        if summary.count == 0 {
            return recording ? "Nothing yet. Play something, or import your Spotify data." : "Nothing stored."
        }
        var line = "\(Self.count(summary.count)) \(summary.count == 1 ? "listen" : "listens")"
        if let first = summary.first { line += " since \(Self.monthYear(first))" }
        return line
    }

    static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func monthYear(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return f.string(from: date)
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d, hour: 12)) ?? Date()
    }
}
