import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The period as a 1080 x 1350 picture to save or send: minutes, top artist, top album,
/// top five songs, the period and a small Tonearm mark. Painted in the top album's colors.
struct ShareCard: View {
    static let size = CGSize(width: 1080, height: 1350)

    var stats: Stats
    var periodTitle: String
    var albumImage: NSImage?
    var albumName: String
    var sleeve: SleeveColors

    private let pad: CGFloat = 80
    private var soft: Color { .white.opacity(SleeveColors.secondaryOpacity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Liner Notes")
                Spacer(minLength: 24)
                Text(periodTitle).lineLimit(1)
            }
            .font(.system(size: 30, weight: .medium))
            .foregroundColor(soft)

            // The answer first: how much, in the biggest type on the card.
            VStack(alignment: .leading, spacing: 0) {
                Text(LinerFormat.number(LinerFormat.minutes(stats.music.ms)))
                    .font(LinerType.serif(140))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: true)
                Text("minutes listened")
                    .font(.system(size: 34))
                    .foregroundColor(soft)
            }
            .padding(.top, 28)

            HStack(alignment: .top, spacing: 48) {
                ArtTile(image: albumImage, name: albumName, size: 280, radius: 10)
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Top artist")
                        .font(.system(size: 26))
                        .foregroundColor(soft)
                    WordClampedText(text: stats.music.topArtists.first?.name ?? "", font: LinerType.serif(54),
                                    lines: 2, color: .white)
                        .padding(.top, 4)
                    if let album = stats.music.topAlbums.first {
                        Text("Top album")
                            .font(.system(size: 26))
                            .foregroundColor(soft)
                            .padding(.top, 28)
                        WordClampedText(text: album.name, font: .system(size: 30, weight: .medium), lines: 2,
                                        color: .white)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 48)

            VStack(alignment: .leading, spacing: 0) {
                Text("Top songs")
                    .font(.system(size: 26))
                    .foregroundColor(soft)
                    .padding(.bottom, 8)
                ForEach(Array(stats.music.topTracks.prefix(5).enumerated()), id: \.element.id) { i, song in
                    HStack(alignment: .firstTextBaseline, spacing: 24) {
                        Text("\(i + 1)")
                            .font(LinerType.mono(28))
                            .foregroundColor(soft)
                            .frame(width: 28, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            WordClampedText(text: song.name, font: .system(size: 32, weight: .medium), lines: 1,
                                            color: .white)
                            WordClampedText(text: song.artist ?? "", font: .system(size: 24), lines: 1, color: soft)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(LinerFormat.minutesText(song.ms))
                            .font(.system(size: 26).monospacedDigit())
                            .foregroundColor(soft)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(.top, 48)

            Spacer(minLength: 16)

            HStack(spacing: 14) {
                TonearmMark(size: 40)
                Text("Tonearm")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .padding(pad)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(sleeve.gradient)
        .environment(\.colorScheme, .dark)
    }

    /// The card for what the model shows now.
    @MainActor
    static func make(_ model: LinerNotesModel) -> ShareCard? {
        guard let s = model.stats, s.music.listens > 0 else { return nil }
        return ShareCard(stats: s, periodTitle: LinerFormat.title(model.period, timeZone: model.timeZone),
                         albumImage: model.topAlbumImage, albumName: model.topAlbumName, sleeve: model.sleeve)
    }

    /// The card as an image, at exactly 1080 x 1350 pixels.
    @MainActor
    func render() -> CGImage? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = 1
        return renderer.cgImage
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// "Liner Notes 2024.png"
    static func fileName(_ title: String) -> String {
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "Liner Notes \(safe).png"
    }
}

/// The share sheet in the window: the card, Save and the macOS share menu.
struct ShareSheet: View {
    @ObservedObject var model: LinerNotesModel
    var done: () -> Void
    @State private var image: NSImage?

    /// `image` is the rendered card, for snapshots; the app renders it when the sheet opens.
    init(model: LinerNotesModel, image: NSImage? = nil, done: @escaping () -> Void) {
        self.model = model
        self.done = done
        _image = State(initialValue: image)
    }
    @State private var file: URL?
    @State private var saved: String?
    /// Why the card can't be shared, when it can't.
    @State private var problem: String?
    @Environment(\.colorScheme) private var scheme

    static let previewScale: CGFloat = 0.36

    var body: some View {
        let p = LinerPalette(scheme)
        VStack(alignment: .leading, spacing: 20) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                } else {
                    p.raised
                }
            }
            .frame(width: ShareCard.size.width * Self.previewScale, height: ShareCard.size.height * Self.previewScale)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(p.hairline))
            .accessibilityElement()
            .accessibilityAddTraits(.isImage)
            .accessibilityLabel(Self.cardDescription(model))

            Text(problem ?? saved ?? "1080 × 1350, the size of a portrait post")
                .font(.system(size: 12))
                .foregroundColor(p.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Done", action: done)
                    .buttonStyle(LinerButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 8)
                Button("Save…", action: save)
                    .buttonStyle(LinerButtonStyle())
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Save the card as a picture (⌘S)")
                    .disabled(image == nil)
                shareButton(p)
            }
        }
        .padding(24)
        .frame(width: ShareCard.size.width * Self.previewScale + 48)
        .background(p.page)
        .onAppear(perform: prepare)
    }

    /// What the card says, for VoiceOver: "Liner Notes card for 2024: 12,345 minutes, top
    /// artist Кино, top song Звезда".
    @MainActor static func cardDescription(_ model: LinerNotesModel) -> String {
        let title = LinerFormat.title(model.period, timeZone: model.timeZone)
        guard let s = model.stats else { return "Liner Notes card for \(title)" }
        var parts = ["\(LinerFormat.number(LinerFormat.minutes(s.music.ms))) minutes"]
        if let a = s.music.topArtists.first { parts.append("top artist \(a.name)") }
        if let t = s.music.topTracks.first { parts.append("top song \(t.name)") }
        return "Liner Notes card for \(title): " + parts.joined(separator: ", ")
    }

    @ViewBuilder private func shareButton(_ p: LinerPalette) -> some View {
        if let file, !model.isSnapshot {
            ShareLink(item: file) { Text("Share…") }
                .buttonStyle(LinerButtonStyle(kind: .primary))
        } else {
            // Only a snapshot shows it enabled: in the app there is no file to share.
            Button("Share…") {}
                .buttonStyle(LinerButtonStyle(kind: .primary))
                .disabled(!model.isSnapshot)
        }
    }

    /// Where the card waits for the share menu. Emptied before each card and when the
    /// window closes, so at most one picture of your listening sits in the temporary folder.
    static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Tonearm Liner Notes", isDirectory: true)
    }

    static func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    /// Renders the card and writes it to a temporary file for the share menu.
    private func prepare() {
        guard image == nil else { return }
        guard let card = ShareCard.make(model) else {
            problem = "Nothing played in this period, so there is no card."
            return
        }
        guard let cg = card.render() else {
            problem = "Couldn’t draw the card."
            return
        }
        image = NSImage(cgImage: cg, size: ShareCard.size)
        guard !model.isSnapshot else { return }
        guard let data = ShareCard.png(cg) else {
            problem = "Couldn’t make a PNG of the card."
            return
        }
        Self.removeTemporaryFiles()
        let url = Self.temporaryDirectory.appendingPathComponent(ShareCard.fileName(card.periodTitle))
        do {
            try FileManager.default.createDirectory(at: Self.temporaryDirectory, withIntermediateDirectories: true)
            try data.write(to: url)
            file = url
        } catch {
            problem = "Can’t share it: \(error.localizedDescription) Save still works."
        }
    }

    private func save() {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = ShareCard.png(cg) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = file?.lastPathComponent
            ?? ShareCard.fileName(LinerFormat.title(model.period, timeZone: model.timeZone))
        panel.canCreateDirectories = true
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
                saved = "Saved to \(url.deletingLastPathComponent().lastPathComponent)"
            } catch {
                saved = "Couldn’t save: \(error.localizedDescription)"
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            panel.begin(completionHandler: handle)
        }
    }
}
