import SwiftUI

struct PlayerView: View {
    @EnvironmentObject var model: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.status {
            case .ready:
                nowPlaying
            case .notRunning:
                message("Spotify isn't running.", button: "Open Spotify", action: model.openSpotify)
            case .notInstalled:
                message("Spotify isn't installed.", button: nil, action: {})
            case .notAuthorized:
                message("Tonearm needs permission to control Spotify.",
                        button: "Open Automation settings", action: model.openAutomationSettings)
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(Color(red: 0.07, green: 0.07, blue: 0.07))
        .environment(\.colorScheme, .dark)
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if let art = model.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.white.opacity(0.08))
                }
            }
            .frame(width: 268, height: 268)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(model.track?.title ?? "Nothing playing")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(model.track?.artist ?? " ")
                    .font(.system(size: 13))
                    .foregroundColor(Color(white: 0.7))
                    .lineLimit(1)
            }

            HStack(spacing: 28) {
                Spacer()
                Button(action: model.previous) { Image(systemName: "backward.fill") }
                Button(action: model.playPause) {
                    ZStack {
                        Circle().fill(Color(red: 0.12, green: 0.84, blue: 0.38))
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundColor(.black)
                    }
                    .frame(width: 44, height: 44)
                }
                Button(action: model.next) { Image(systemName: "forward.fill") }
                Spacer()
            }
            .buttonStyle(.plain)
            .font(.system(size: 16))
            .foregroundColor(.white)
        }
    }

    private func message(_ text: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(text).foregroundColor(Color(white: 0.7))
            if let button {
                Button(button, action: action)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
