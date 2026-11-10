import AppKit
import SwiftUI

/// Renders the popover with sample data to a PNG. Used by CI for screenshots:
/// `Tonearm --snapshot out.png`
enum Snapshot {
    @MainActor
    static func render(to url: URL) {
        let model = PlayerModel(live: false)
        model.setPreview(
            Playback(
                state: .playing,
                track: Track(id: "sample", title: "Sample Song Title", artist: "Sample Artist",
                             album: "Sample Album", artworkURL: nil, duration: 214),
                position: 83,
                volume: 70
            ),
            artwork: sampleArtwork()
        )
        let renderer = ImageRenderer(content: PlayerView().environmentObject(model))
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write("snapshot: render failed\n".data(using: .utf8)!)
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func sampleArtwork() -> NSImage {
        let size = NSSize(width: 600, height: 600)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [
                NSColor(red: 0.85, green: 0.35, blue: 0.25, alpha: 1),
                NSColor(red: 0.25, green: 0.15, blue: 0.45, alpha: 1),
            ])?.draw(in: rect, angle: -60)
            return true
        }
    }
}
