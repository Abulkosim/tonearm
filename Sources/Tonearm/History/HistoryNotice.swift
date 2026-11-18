import Foundation
import SwiftUI

/// Tells people once that Tonearm keeps a record of what they play. Recording came with
/// Liner Notes and is on by default, so someone who updated from an earlier version would
/// otherwise never hear of it. They get a short note in the player the first time they open
/// it after the update. A new install says the same in the welcome window, and the player
/// stays quiet.
///
/// Once means one opening of the player: the note is marked seen when it appears, stays until
/// the player closes or the person acts on it, and never comes back.
@MainActor
final class HistoryNotice: ObservableObject {
    static let shared = HistoryNotice(defaults: .standard)
    static let seenKey = "historyNoticeSeen"

    @Published private(set) var isShowing = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var seen: Bool { defaults.bool(forKey: Self.seenKey) }

    /// At launch, before the welcome window. A first launch shows the welcome window, which
    /// says it, so the player won't.
    func launched(firstLaunch: Bool) {
        if firstLaunch { markSeen() }
    }

    /// The player opened. Shows the note if it was never seen and recording is on.
    func playerOpened(recording: Bool) {
        guard !isShowing, !seen, recording else { return }
        markSeen()
        isShowing = true
    }

    func playerClosed() {
        isShowing = false
    }

    /// The close button, or one of the note's buttons.
    func dismiss() {
        isShowing = false
        markSeen()
    }

    private func markSeen() {
        defaults.set(true, forKey: Self.seenKey)
    }
}

/// The note itself: on the cover in the large player, under the controls otherwise.
struct HistoryNoticeView: View {
    /// Drawn over the cover, so it needs a solid backing to read on any art.
    var onCover = false
    var openLinerNotes: () -> Void
    var turnOff: () -> Void
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text("Tonearm now keeps a private record of what you play, on this Mac only.")
                    .font(.system(size: 12))
                    .foregroundColor(PlayerTheme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(IconButtonStyle())
                .help("Close")
                .accessibilityLabel("Close")
            }
            HStack(spacing: 12) {
                Button("Open Liner Notes", action: openLinerNotes)
                    .buttonStyle(TextButtonStyle())
                    .help("Liner Notes (⌘L)")
                Button("Turn off", action: turnOff)
                    .buttonStyle(TextButtonStyle())
                    .help("Stop recording. Settings › History turns it back on.")
            }
            .padding(.horizontal, -4)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(onCover ? PlayerTheme.base.opacity(0.92) : Color.white.opacity(0.07)))
        .accessibilityElement(children: .contain)
    }
}
