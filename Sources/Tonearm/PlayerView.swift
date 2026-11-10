import AppKit
import SwiftUI

struct PlayerView: View {
    /// Fixed state for snapshots. The app passes nothing.
    struct Preview {
        var status: PlayerModel.Status?
        var progressHover = false
        var settingsOpen = false
        var layout: PlayerLayout?
        var shuffling: Bool?
        var repeating: Bool?
        var coverHover = false
        /// Text of the note shown next to the cover buttons, like "Copied".
        var coverNote: String?
        /// Spotify's process is up but has not answered yet.
        var connecting = false
    }

    /// Nil in the app.
    private let preview: Preview?

    init(preview: Preview? = nil) {
        self.preview = preview
        _showSettings = State(initialValue: preview?.settingsOpen ?? false)
        _coverNote = State(initialValue: preview?.coverNote)
    }

    @EnvironmentObject var model: PlayerModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var showSettings: Bool
    /// Seconds under the pointer while dragging the progress bar.
    @State private var scrubSeconds: Double?
    /// Volume to go back to when unmuting.
    @State private var volumeBeforeMute = 50
    @State private var hoveringCover = false
    /// "Copied" or "No link", shown on the cover for a moment after copying the song link.
    @State private var coverNote: String?
    @State private var copyCount = 0
    @State private var keys = PopoverKeys()
    /// Bumped each time the window closes. The panels are rebuilt under a new id, so hover
    /// states that never got their "mouse left" event start fresh on the next open.
    @State private var session = 0

    private static let width: CGFloat = 300
    private static let padding: CGFloat = 16
    private static let coverSize = width - padding * 2
    private static let compactCoverSize: CGFloat = 56

    private var isSnapshot: Bool { preview != nil }
    private var status: PlayerModel.Status { preview?.status ?? model.status }
    private var layout: PlayerLayout { preview?.layout ?? settings.layout }
    private var shuffling: Bool { preview?.shuffling ?? model.shuffling }
    private var repeating: Bool { preview?.repeating ?? model.repeating }

    var body: some View {
        ZStack(alignment: .top) {
            if showSettings {
                settingsPanel
                    .transition(.opacity)
            } else {
                playerPanel
                    .transition(.opacity)
            }
        }
        .id(session)
        .frame(width: Self.width)
        .fitsMenuBarWindow(!isSnapshot, onWindow: model.attachPopoverWindow)
        .background(ArtworkBackground(colors: showSettings || status != .ready ? nil : model.artworkColors))
        .popoverWindowShape(!isSnapshot)
        .environment(\.colorScheme, .dark)
        .hidesSystemFocusRing()
        .onAppear(perform: appeared)
        .onDisappear(perform: disappeared)
        .onChange(of: model.popoverVisible) { visible in
            if visible { appeared() } else { disappeared() }
        }
        .onChange(of: trackKey) { _ in scrubSeconds = nil }
        .onChange(of: canSeek) { if !$0 { scrubSeconds = nil } }
    }

    // MARK: Panels

    @ViewBuilder private var playerPanel: some View {
        if status == .ready && layout == .compact {
            compactPlayer
                .padding(Self.padding)
        } else {
            VStack(spacing: 0) {
                playerHeader
                    .padding(.bottom, 12)
                if status == .ready {
                    largePlayer
                } else {
                    statusScreen
                }
            }
            .padding(.horizontal, Self.padding)
            .padding(.top, 12)
            .padding(.bottom, Self.padding)
        }
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            .help("Back to player (Esc)")
            .accessibilityLabel("Back to player")
            .padding(.bottom, 8)

            SettingsView(notificationsDenied: model.notificationsDenied,
                         openNotificationSettings: model.openNotificationSettings)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.padding)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var playerHeader: some View {
        HStack(spacing: 8) {
            Text(headerTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(PlayerTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            settingsButton
        }
        .frame(height: 24)
    }

    private var settingsButton: some View {
        Button(action: toggleSettings) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13))
                .frame(width: 24, height: 24, alignment: .trailing)
        }
        .buttonStyle(IconButtonStyle())
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings")
    }

    private var headerTitle: String {
        guard status == .ready, let album = model.track?.album, !album.isEmpty else { return "" }
        return album
    }

    private func toggleSettings() {
        withAnimation(PlayerTheme.medium) { showSettings.toggle() }
    }

    /// True while the Spotify process exists, even before it answers Apple Events.
    private var spotifyAppearsRunning: Bool { preview?.connecting ?? model.spotifyRunning }

    /// Puts the window back to the player, for the next time it opens.
    private func resetForNextOpen() {
        showSettings = false
        hoveringCover = false
        scrubSeconds = nil
        coverNote = nil
        session += 1
    }

    // MARK: Status screens

    @ViewBuilder private var statusScreen: some View {
        switch status {
        case .ready:
            EmptyView()
        case .notRunning where model.isLaunching:
            StatusMessage(
                symbol: "music.note",
                title: "Starting Spotify…",
                detail: "The player shows up here once Spotify is ready"
            ) {
                EmptyView()
            }
        case .notRunning where spotifyAppearsRunning:
            // Running but not answering yet: still starting, on its login screen, or busy.
            StatusMessage(
                symbol: "music.note",
                title: "Connecting to Spotify…",
                detail: "If Spotify shows a login screen, sign in there"
            ) {
                Button("Show Spotify", action: model.showInSpotify)
                    .buttonStyle(TextButtonStyle())
            }
        case .notRunning:
            StatusMessage(
                symbol: "music.note",
                title: "Spotify isn't running",
                detail: "Open it to see what's playing and control it from the menu bar"
            ) {
                Button("Open Spotify", action: model.openSpotify)
                    .buttonStyle(PillButtonStyle())
            }
        case .notInstalled:
            StatusMessage(
                symbol: "arrow.down.circle",
                title: "Spotify isn't installed",
                detail: "Tonearm works with the Spotify desktop app"
            ) {
                Button("Get Spotify") { NSWorkspace.shared.open(Onboarding.spotifyDownloadURL) }
                    .buttonStyle(PillButtonStyle())
                    .help("Opens spotify.com/download")
            }
        case .notAuthorized where model.isAskingPermission:
            StatusMessage(
                symbol: "hand.raised.fill",
                title: "Waiting for permission",
                detail: "Click OK in the macOS dialog to let Tonearm control Spotify"
            ) {
                EmptyView()
            }
        case .notAuthorized:
            StatusMessage(
                symbol: "lock.fill",
                title: "Tonearm needs permission",
                detail: "Turn on Spotify under Tonearm in Privacy & Security › Automation, then try again"
            ) {
                Button("Open System Settings", action: model.openAutomationSettings)
                    .buttonStyle(PillButtonStyle())
                Button("Try again", action: model.requestPermission)
                    .buttonStyle(TextButtonStyle())
            }
        }
    }

    // MARK: Large layout

    private var largePlayer: some View {
        VStack(alignment: .leading, spacing: 0) {
            largeCover
            trackInfo(titleSize: 17, artistSize: 13)
                .padding(.top, 16)
            progress
                .padding(.top, 12)
            transport(compact: false)
                .padding(.top, 4)
            volume
                .padding(.top, 12)
        }
    }

    private var trackKey: String { model.track?.id ?? "none" }

    /// Changes with the track and when its artwork arrives.
    private var coverKey: String {
        let art = model.artwork.map { String(ObjectIdentifier($0).hashValue) } ?? "-"
        return "\(trackKey)#\(art)"
    }

    private var showCoverActions: Bool {
        model.track != nil && (hoveringCover || preview?.coverHover == true)
    }

    private var largeCover: some View {
        ZStack {
            CoverView(image: model.artwork, size: Self.coverSize)
                .id(coverKey)
                .transition(.opacity)
        }
        .frame(width: Self.coverSize, height: Self.coverSize)
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        .animation(PlayerTheme.fade, value: coverKey)
        .overlay(alignment: .topTrailing) {
            if showCoverActions {
                CoverActions(canCopy: model.trackURL != nil || isSnapshot, note: coverNote,
                             open: model.showInSpotify, copy: copyLink)
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .onHover { inside in
            withAnimation(PlayerTheme.quick) { hoveringCover = inside }
        }
        .contextMenu { coverMenu }
    }

    @ViewBuilder private var coverMenu: some View {
        Button("Open in Spotify", action: model.showInSpotify)
        Button("Copy song link", action: copyLink)
            .disabled(model.trackURL == nil)
    }

    /// Copies the link and shows "Copied" (or "No link" for local files and ads) once,
    /// fading out after a moment.
    private func copyLink() {
        let note = model.copyTrackLink() ? "Copied" : "No link"
        copyCount += 1
        let count = copyCount
        withAnimation(PlayerTheme.medium) { coverNote = note }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard copyCount == count else { return }
            withAnimation(PlayerTheme.fade) { coverNote = nil }
        }
    }

    private func trackInfo(titleSize: CGFloat, artistSize: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: titleSize > 15 ? 4 : 2) {
                LinkText(
                    text: model.track?.title ?? "Nothing playing",
                    font: .system(size: titleSize, weight: .bold),
                    color: .white,
                    enabled: model.track != nil,
                    action: model.showInSpotify
                )
                // The full title, for one cut short.
                .help(model.track?.title ?? "")
                Text(model.track?.artist ?? "Play something in Spotify")
                    .font(.system(size: artistSize))
                    .foregroundColor(PlayerTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(model.track?.artist ?? "")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(trackKey)
            .transition(.opacity)
        }
        .animation(PlayerTheme.fade, value: trackKey)
        .accessibilityAction(named: Text("Open in Spotify"), model.showInSpotify)
        .accessibilityAction(named: Text("Copy song link"), copyLink)
    }

    // MARK: Compact layout

    private var compactPlayer: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: model.showInSpotify) {
                    CoverView(image: model.artwork, size: Self.compactCoverSize, cornerRadius: 4)
                        .id(coverKey)
                        .transition(.opacity)
                        .animation(PlayerTheme.fade, value: coverKey)
                }
                .buttonStyle(PressDimStyle())
                .help("Open in Spotify")
                .contextMenu { coverMenu }
                .accessibilityLabel("Open in Spotify")

                trackInfo(titleSize: 14, artistSize: 12)
                    .frame(height: Self.compactCoverSize)

                settingsButton
            }
            compactProgress
                .padding(.top, 12)
            transport(compact: true)
                .padding(.top, 8)
        }
    }

    // MARK: Progress

    /// Redraws the playhead twice a second while a song plays in an open window, and not at all
    /// otherwise. Model changes (seek, pause, a new song) redraw it anyway.
    private var playheadSchedule: AnimationTimelineSchedule {
        .animation(minimumInterval: 0.5, paused: isSnapshot || !model.isPlaying || !model.popoverVisible)
    }

    private var progress: some View {
        TimelineView(playheadSchedule) { context in
            let head = playhead(at: context.date)
            let position = head.position
            let duration = head.duration
            let shown = scrubSeconds ?? position
            VStack(spacing: 4) {
                progressBar(position: position, duration: duration)
                HStack {
                    Text(PlayerTheme.time(shown, hours: duration >= 3600))
                    Spacer()
                    Text(remaining(shown, duration))
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(PlayerTheme.textSecondary)
                .accessibilityHidden(true)
            }
        }
        .disabled(!canSeek)
    }

    private var compactProgress: some View {
        TimelineView(playheadSchedule) { context in
            let head = playhead(at: context.date)
            let position = head.position
            let duration = head.duration
            let shown = scrubSeconds ?? position
            HStack(spacing: 8) {
                Text(PlayerTheme.time(shown, hours: duration >= 3600))
                    .frame(minWidth: 28, alignment: .leading)
                    .accessibilityHidden(true)
                progressBar(position: position, duration: duration)
                Text(remaining(shown, duration))
                    .frame(minWidth: 32, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundColor(PlayerTheme.textSecondary)
        }
        .disabled(!canSeek)
    }

    /// Seeking needs a song of known length; with no duration every click would jump to 0.
    private var canSeek: Bool { model.track != nil && (model.track?.duration ?? 0) > 0 }

    private func playhead(at date: Date) -> (position: Double, duration: Double) {
        let duration = max(model.track?.duration ?? 0, 0)
        return (min(model.position(at: date), duration), duration)
    }

    private func remaining(_ shown: Double, _ duration: Double) -> String {
        duration > 0 ? "-" + PlayerTheme.time(duration - shown) : PlayerTheme.time(0)
    }

    private func progressBar(position: Double, duration: Double) -> some View {
        ScrubBar(
            value: duration > 0 ? position / duration : 0,
            accessibilityLabel: "Playback position",
            accessibilityValueText: "\(PlayerTheme.time(position)) of \(PlayerTheme.time(duration))",
            forceActive: preview?.progressHover ?? false,
            step: duration > 0 ? min(1, KeyCommand.seekStep / duration) : 0.05,
            onScrub: { scrubSeconds = $0 * duration },
            onCommit: { v in
                scrubSeconds = nil
                model.seek(to: v * duration)
            }
        )
        // A new song drops a drag in progress, so it never seeks the wrong song.
        .id(trackKey)
    }

    // MARK: Controls

    private func transport(compact: Bool) -> some View {
        let glyph: CGFloat = compact ? 16 : 18
        return HStack(spacing: 0) {
            Button(action: model.toggleShuffle) {
                Image(systemName: "shuffle")
            }
            .buttonStyle(ModeButtonStyle(isOn: shuffling))
            .help(shuffling ? "Shuffle is on (S)" : "Shuffle (S)")
            .accessibilityLabel("Shuffle")
            .accessibilityValue(shuffling ? "On" : "Off")
            // Lines the glyph up with the edge of the progress bar.
            .padding(.leading, -8)

            Spacer(minLength: 0)

            HStack(spacing: compact ? 16 : 24) {
                Button(action: model.previous) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: glyph))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(IconButtonStyle())
                .help("Previous (⌘←)")
                .accessibilityLabel("Previous track")

                Button(action: model.playPause) {
                    PlayPauseGlyph(isPlaying: model.isPlaying)
                        .font(.system(size: compact ? 15 : 18, weight: .bold))
                }
                .buttonStyle(PlayButtonStyle(diameter: compact ? 36 : 44))
                .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

                Button(action: model.next) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: glyph))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(IconButtonStyle())
                .help("Next (⌘→)")
                .accessibilityLabel("Next track")
            }

            Spacer(minLength: 0)

            Button(action: model.toggleRepeat) {
                Image(systemName: "repeat")
            }
            .buttonStyle(ModeButtonStyle(isOn: repeating))
            .help(repeating ? "Repeat is on (R)" : "Repeat (R)")
            .accessibilityLabel("Repeat")
            .accessibilityValue(repeating ? "On" : "Off")
            .padding(.trailing, -8)
        }
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
            .help(level == 0 ? "Unmute" : "Mute")
            .accessibilityLabel(level == 0 ? "Unmute" : "Mute")

            ScrubBar(
                value: Double(level) / 100,
                accessibilityLabel: "Volume",
                accessibilityValueText: "\(level) percent",
                step: Double(KeyCommand.volumeStep) / 100,
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

    // MARK: Keyboard

    // A MenuBarExtra window does not reliably call onAppear and onDisappear after the first
    // open, so these also follow `model.popoverVisible`. Both are safe to call twice.

    private func appeared() {
        guard !isSnapshot else { return }
        model.popoverVisible = true
        keys.start(window: { model.popoverWindow }, handle)
    }

    private func disappeared() {
        guard !isSnapshot else { return }
        model.popoverVisible = false
        keys.stop()
        resetForNextOpen()
    }

    private func handle(_ command: KeyCommand) -> Bool {
        switch command {
        case .back:
            // Outside settings, Escape goes on to the window, which closes.
            guard showSettings else { return false }
            toggleSettings()
        case .playPause: model.playPause()
        case .seekBack: model.seek(by: -KeyCommand.seekStep)
        case .seekForward: model.seek(by: KeyCommand.seekStep)
        case .previous: model.previous()
        case .next: model.next()
        case .volumeUp: model.changeVolume(by: KeyCommand.volumeStep)
        case .volumeDown: model.changeVolume(by: -KeyCommand.volumeStep)
        case .shuffle: model.toggleShuffle()
        case .repeating: model.toggleRepeat()
        case .settings: toggleSettings()
        case .quit: NSApp.terminate(nil)
        }
        return true
    }
}

extension View {
    /// Rounded corners and a faint rim, the shape of the menu bar window.
    @ViewBuilder func popoverWindowShape(_ enabled: Bool = true) -> some View {
        if enabled {
            let shape = RoundedRectangle(cornerRadius: PlayerTheme.windowRadius, style: .continuous)
            clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        } else {
            self
        }
    }
}
