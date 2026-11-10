import AppKit
import SwiftUI

struct PlayerView: View {
    /// Options for snapshots. The app uses the defaults.
    struct Preview {
        var status: PlayerModel.Status?
        var progressHover = false
        var settingsOpen = false
    }

    var preview: Preview

    init(preview: Preview = Preview()) {
        self.preview = preview
        _showSettings = State(initialValue: preview.settingsOpen)
    }

    @EnvironmentObject var model: PlayerModel
    @State private var showSettings = false
    /// Seconds under the pointer while dragging the progress bar.
    @State private var scrubSeconds: Double?
    /// Volume to go back to when unmuting.
    @State private var volumeBeforeMute = 50

    private static let width: CGFloat = 300
    private static let padding: CGFloat = 16
    private static let coverSize = width - padding * 2

    private var status: PlayerModel.Status { preview.status ?? model.status }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.bottom, 12)
            ZStack(alignment: .top) {
                if showSettings {
                    SettingsView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                } else {
                    content
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, Self.padding)
        .padding(.top, 12)
        .padding(.bottom, Self.padding)
        .frame(width: Self.width)
        .background(ArtworkBackground(colors: status == .ready ? model.artworkColors : nil))
        .environment(\.colorScheme, .dark)
        .onAppear { model.popoverVisible = true }
        .onDisappear { model.popoverVisible = false }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if showSettings {
                Button(action: toggleSettings) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Settings")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .frame(height: 24)
                }
                .buttonStyle(IconButtonStyle(isActive: true))
                .accessibilityLabel("Back to player")
                .transition(.opacity)
            } else {
                Text(headerTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(PlayerTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.opacity)
            }
            Spacer(minLength: 8)
            Button(action: toggleSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24, alignment: .trailing)
            }
            .buttonStyle(IconButtonStyle(isActive: showSettings))
            .accessibilityLabel(showSettings ? "Close settings" : "Settings")
        }
        .frame(height: 24)
    }

    private func toggleSettings() {
        withAnimation(PlayerTheme.medium) { showSettings.toggle() }
    }

    private var headerTitle: String {
        guard status == .ready, let album = model.track?.album, !album.isEmpty else { return "" }
        return album
    }

    // MARK: States

    @ViewBuilder private var content: some View {
        switch status {
        case .ready:
            nowPlaying
        case .notRunning:
            StatusMessage(
                symbol: "music.note",
                title: "Spotify isn't running",
                detail: "Open it to see what's playing and control it from the menu bar"
            ) {
                Button(model.isLaunching ? "Starting Spotify…" : "Open Spotify", action: model.openSpotify)
                    .buttonStyle(PillButtonStyle())
                    .disabled(model.isLaunching)
            }
        case .notInstalled:
            StatusMessage(
                symbol: "arrow.down.circle",
                title: "Spotify isn't installed",
                detail: "Tonearm works with the Spotify desktop app"
            ) {
                Button {
                    if let url = URL(string: "https://www.spotify.com/download") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Get it at spotify.com/download").underline()
                }
                .buttonStyle(TextButtonStyle())
            }
        case .notAuthorized:
            StatusMessage(
                symbol: "lock.fill",
                title: "Tonearm needs permission",
                detail: "Allow Tonearm to control Spotify in System Settings, then try again"
            ) {
                Button("Open Automation Settings", action: model.openAutomationSettings)
                    .buttonStyle(PillButtonStyle())
                Button("Try again", action: model.requestPermission)
                    .buttonStyle(TextButtonStyle())
            }
        }
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            trackInfo
                .padding(.top, 16)
            progress
                .padding(.top, 12)
            transport
                .padding(.top, 4)
            volume
                .padding(.top, 12)
        }
    }

    private var trackKey: String { model.track?.id ?? "none" }

    private var cover: some View {
        ZStack {
            CoverView(image: model.artwork, size: Self.coverSize)
                .id(coverKey)
                .transition(.opacity)
        }
        .frame(width: Self.coverSize, height: Self.coverSize)
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .animation(PlayerTheme.fade, value: coverKey)
    }

    /// Changes with the track and when its artwork arrives.
    private var coverKey: String {
        let art = model.artwork.map { String(ObjectIdentifier($0).hashValue) } ?? "-"
        return "\(trackKey)#\(art)"
    }

    private var trackInfo: some View {
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.track?.title ?? "Nothing playing")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(model.track?.artist ?? "Play something in Spotify")
                    .font(.system(size: 13))
                    .foregroundColor(PlayerTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(trackKey)
            .transition(.opacity)
        }
        .animation(PlayerTheme.fade, value: trackKey)
        .accessibilityElement(children: .combine)
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = max(model.track?.duration ?? 0, 0)
            let position = min(model.position(at: context.date), duration)
            let shown = scrubSeconds ?? position
            VStack(spacing: 4) {
                ScrubBar(
                    value: duration > 0 ? position / duration : 0,
                    accessibilityLabel: "Playback position",
                    accessibilityValueText: "\(PlayerTheme.time(position)) of \(PlayerTheme.time(duration))",
                    forceActive: preview.progressHover,
                    step: duration > 0 ? min(1, 10 / duration) : 0.05,
                    onScrub: { scrubSeconds = $0 * duration },
                    onCommit: { v in
                        scrubSeconds = nil
                        model.seek(to: v * duration)
                    }
                )
                HStack {
                    Text(PlayerTheme.time(shown))
                    Spacer()
                    Text(duration > 0 ? "-" + PlayerTheme.time(duration - shown) : PlayerTheme.time(0))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(PlayerTheme.textSecondary)
                .accessibilityHidden(true)
            }
        }
        .disabled(model.track == nil)
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Button(action: model.previous) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 18))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Previous track")

            Button(action: model.playPause) {
                PlayPauseGlyph(isPlaying: model.isPlaying)
                    .font(.system(size: 18, weight: .bold))
            }
            .buttonStyle(PlayButtonStyle())
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            Button(action: model.next) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 18))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Next track")
        }
        .frame(maxWidth: .infinity)
    }

    private var volume: some View {
        let level = model.playback.volume
        return HStack(spacing: 8) {
            Button(action: toggleMute) {
                Image(systemName: Self.volumeSymbol(level))
                    .font(.system(size: 13))
                    .frame(width: 20, height: 20, alignment: .leading)
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel(level == 0 ? "Unmute" : "Mute")

            ScrubBar(
                value: Double(level) / 100,
                accessibilityLabel: "Volume",
                accessibilityValueText: "\(level) percent",
                step: 0.1,
                onScrub: { model.setVolume(Int(($0 * 100).rounded())) },
                onCommit: { model.setVolume(Int(($0 * 100).rounded())) }
            )
        }
    }

    private func toggleMute() {
        let level = model.playback.volume
        if level > 0 {
            volumeBeforeMute = level
            model.setVolume(0)
        } else {
            model.setVolume(max(volumeBeforeMute, 10))
        }
    }

    static func volumeSymbol(_ level: Int) -> String {
        switch level {
        case ..<1: return "speaker.slash.fill"
        case ..<34: return "speaker.wave.1.fill"
        case ..<67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}
