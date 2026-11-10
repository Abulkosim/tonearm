import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        if let track = model.track, model.status == .ready {
            Text(Self.shorten("\(track.title) · \(track.artist)", to: 32))
        } else {
            Image(systemName: "music.note")
        }
    }

    static func shorten(_ s: String, to max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
