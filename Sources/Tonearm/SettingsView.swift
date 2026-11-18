import AppKit
import SwiftUI

/// Settings panel shown inside the popover. Reads the `AppSettings.shared`,
/// `LaunchAtLogin.shared`, `Updater.shared`, `HistorySettingsModel.shared` and
/// `ListenBrainzSync.shared` singletons, so it needs no environment objects. It has no outer
/// padding or background: the host adds them.
struct SettingsView: View {
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var login = LaunchAtLogin.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var history: HistorySettingsModel
    @ObservedObject private var listenBrainz: ListenBrainzSync
    /// Typed into the ListenBrainz token field. Never stored; the Keychain keeps the token.
    @State private var token = ""
    /// macOS blocks Tonearm's notifications while "Notify on song change" is on.
    private let notificationsDenied: Bool
    private let openNotificationSettings: () -> Void
    /// Fixed values for snapshots. Nil in the app, which asks the real objects.
    private let loginNeedsApprovalPreview: Bool?
    private let canCheckForUpdatesPreview: Bool?
    /// Snapshots can't draw a text field, so they get a drawn one.
    private let isSnapshot: Bool

    init(settings: AppSettings = .shared,
         notificationsDenied: Bool = false, openNotificationSettings: @escaping () -> Void = {},
         loginNeedsApproval: Bool? = nil, canCheckForUpdates: Bool? = nil,
         history: HistorySettingsModel? = nil, listenBrainz: ListenBrainzSync? = nil, token: String = "") {
        _settings = ObservedObject(wrappedValue: settings)
        _history = ObservedObject(wrappedValue: history ?? .shared)
        _listenBrainz = ObservedObject(wrappedValue: listenBrainz ?? .shared)
        _token = State(initialValue: token)
        isSnapshot = history != nil
        self.notificationsDenied = notificationsDenied
        self.openNotificationSettings = openNotificationSettings
        loginNeedsApprovalPreview = loginNeedsApproval
        canCheckForUpdatesPreview = canCheckForUpdates
    }

    private var loginNeedsApproval: Bool { loginNeedsApprovalPreview ?? login.needsApproval }
    private var canCheckForUpdates: Bool { canCheckForUpdatesPreview ?? updater.canCheck }

    static let repoURL = URL(string: "https://github.com/Abulkosim/tonearm")!

    /// The system-wide combos registered when "Global shortcuts" is on.
    static var globalCombos: [(keys: String, action: String)] {
        HotKeys.Action.allCases.map { ($0.keys, $0.title) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Menu bar") {
                SegmentedChoice(selection: $settings.menuBarStyle, options: [
                    .init(value: .songTitle, title: "Song title"),
                    .init(value: .iconOnly, title: "Icon only"),
                ])
            }
            if settings.menuBarStyle == .songTitle {
                row("Show artist") {
                    GreenSwitch(isOn: $settings.showArtist, label: "Show artist")
                }
                .transition(.opacity)
                row("Title length") {
                    LengthStepper(value: $settings.maxTitleLength)
                }
                .transition(.opacity)
            }

            divider

            row("Layout") {
                SegmentedChoice(selection: $settings.layout, options: [
                    .init(value: .large, title: "Large"),
                    .init(value: .compact, title: "Compact"),
                ])
            }
            row("Notify on song change") {
                GreenSwitch(isOn: $settings.notifyOnTrackChange, label: "Notify on song change")
            }
            if notificationsDenied {
                note("Notifications are off", action: "Open Settings", openNotificationSettings)
                    .transition(.opacity)
            }

            divider

            row("Launch at login") {
                GreenSwitch(isOn: Binding(get: { login.isOn }, set: { login.setEnabled($0) }),
                            label: "Launch at login")
            }
            if loginNeedsApproval {
                note("Needs your approval", action: "Open Login Items", login.openLoginItems)
            }
            row("Global shortcuts") {
                GreenSwitch(isOn: $settings.globalShortcuts, label: "Global shortcuts")
            }
            // Dimmed while off, so it reads as what the switch turns on.
            ShortcutList(items: Self.globalCombos, keyWidth: Self.keyColumn)
                .opacity(settings.globalShortcuts ? 1 : 0.5)
                .padding(.bottom, 4)
                .accessibilityElement(children: .combine)

            divider

            sectionTitle("In the player")
            HStack(alignment: .top, spacing: 16) {
                ShortcutList(items: Array(KeyCommand.help.prefix(4)), keyWidth: Self.keyColumn)
                ShortcutList(items: Array(KeyCommand.help.dropFirst(4)), keyWidth: 28)
            }
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)

            divider

            historySection

            divider

            listenBrainzSection

            divider

            row("Check for updates automatically") {
                GreenSwitch(isOn: $updater.automaticallyChecks, label: "Check for updates automatically")
            }
            actionRow("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!canCheckForUpdates)

            divider

            actionRow("Show welcome") { Onboarding.showWelcome() }
            actionRow("Quit Tonearm", keys: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)

            HStack {
                Text("Version \(Self.version)")
                    .foregroundColor(Theme.muted)
                Spacer()
                Button("Source on GitHub") { NSWorkspace.shared.open(Self.repoURL) }
                    .buttonStyle(QuietButtonStyle(color: Theme.secondary, hover: .white))
            }
            .font(.system(size: 12))
            .frame(height: 24)
        }
        .font(.system(size: 13))
        .foregroundColor(.white)
        .animation(Theme.ease, value: settings.menuBarStyle)
        .animation(Theme.ease, value: loginNeedsApproval)
        .animation(Theme.ease, value: settings.globalShortcuts)
        .animation(Theme.ease, value: notificationsDenied)
        .animation(Theme.ease, value: settings.listenBrainz)
        .animation(Theme.ease, value: history.confirmingDelete)
        .onAppear {
            login.refresh()
            history.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.secondary)
            .frame(height: 24)
    }

    // MARK: History

    @ViewBuilder private var historySection: some View {
        sectionTitle("History")
        row("Record listening") {
            GreenSwitch(isOn: $settings.recordHistory, label: "Record listening")
        }
        line(history.summaryLine(recording: settings.recordHistory))

        actionRow(history.isImporting ? "Importing…" : "Import Spotify data…") { history.chooseImport() }
            .disabled(history.isImporting || history.confirmingDelete || history.isBusy)
            .help("The .zip Spotify sends from Account › Privacy › Download your data")
        if history.isImporting {
            progressLine(importProgressText, fraction: history.progress.map {
                Double($0.filesDone) / Double(max(1, $0.filesTotal))
            })
        }
        resultNote(.imported)

        row("Export") {
            HStack(spacing: 4) {
                smallButton("CSV") { history.chooseExport(.csv) }
                smallButton("JSON") { history.chooseExport(.json) }
            }
            .disabled((history.summary?.count ?? 0) == 0 || history.isBusy)
        }
        resultNote(.exported)

        if history.confirmingDelete {
            deleteConfirmation
                .transition(.opacity)
        } else {
            actionRow("Delete all history…") { history.confirmingDelete = true }
                .disabled((history.summary?.count ?? 0) == 0 || history.isImporting)
        }
        resultNote(.deleted)

        privacyNote
    }

    /// Where the history is. The path gets its own line so it never breaks at a slash.
    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Stored only on this Mac, in")
                Spacer(minLength: 0)
                Button("Show in Finder") { history.showInFinder() }
                    .buttonStyle(QuietButtonStyle(color: Theme.accent, hover: Theme.accentHover))
                    .fixedSize()
            }
            Text(history.displayFolder)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12))
        .foregroundColor(Theme.secondary)
        .padding(.vertical, 4)
        .padding(.bottom, 4)
    }

    private var importProgressText: String {
        guard let p = history.progress, p.filesTotal > 0 else { return "Opening…" }
        let file = min(p.filesDone + 1, p.filesTotal)
        return "Reading file \(file) of \(p.filesTotal), \(HistorySettingsModel.count(p.rowsRead)) rows so far"
    }

    private var deleteConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delete \(history.deletedWords) from this Mac? "
                 + "This can't be undone. Listens already sent to ListenBrainz stay there.")
                .font(.system(size: 12))
                .foregroundColor(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                smallButton("Cancel") { history.confirmingDelete = false }
                smallButton("Delete", color: Theme.danger) {
                    Task { await history.deleteAll(listenBrainz: listenBrainz) }
                }
                .disabled(history.isBusy || history.isImporting)
            }
        }
        .padding(.vertical, 4)
        .padding(.bottom, 4)
    }

    /// The last import, export or delete result, under its row.
    @ViewBuilder private func resultNote(_ action: HistorySettingsModel.Action) -> some View {
        if let n = history.note, n.action == action {
            if let file = n.file {
                note(n.text, action: "Show") { history.showInFinder(file) }
            } else {
                line(n.text, color: n.isError ? Theme.danger : Theme.secondary)
            }
        }
    }

    // MARK: ListenBrainz

    @ViewBuilder private var listenBrainzSection: some View {
        row("Send to ListenBrainz") {
            GreenSwitch(isOn: $settings.listenBrainz, label: "Send to ListenBrainz")
        }
        if settings.listenBrainz {
            switch listenBrainz.connection {
            case .connected:
                connectedRows
            case .noToken, .checking, .tokenRejected:
                tokenRows
            }
        } else {
            line("Off. Nothing leaves this Mac.")
        }
    }

    @ViewBuilder private var tokenRows: some View {
        let checking = listenBrainz.connection == .checking
        HStack(spacing: 8) {
            tokenField
            smallButton(checking ? "Checking…" : "Connect", color: Theme.accent) { connect() }
                .disabled(checking || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .frame(height: 32)
        if let problem = listenBrainz.problem {
            line(problem, color: Theme.danger)
        }
        if listenBrainz.connection == .tokenRejected {
            rejectedRow
        }
        note("Paste your user token from ListenBrainz. It is kept in your Keychain.", action: "Get token") {
            NSWorkspace.shared.open(ListenBrainz.settingsPage)
        }
    }

    /// The old token is still in the Keychain, and plays wait for a new one. Remove token
    /// deletes both.
    private var rejectedRow: some View {
        let n = listenBrainz.saved.pending.count
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(n == 0 ? "Nothing waiting to send."
                 : "\(HistorySettingsModel.count(n)) \(n == 1 ? "listen waits" : "listens wait") for a new token.")
                .foregroundColor(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            removeTokenButton
        }
        .font(.system(size: 12))
        .padding(.bottom, 4)
    }

    private var removeTokenButton: some View {
        Button("Remove token") { listenBrainz.disconnect() }
            .buttonStyle(QuietButtonStyle(color: Theme.secondary, hover: .white))
            .fixedSize()
    }

    private func connect() {
        let typed = token
        Task {
            await listenBrainz.connect(token: typed)
            if listenBrainz.connection == .connected { token = "" }
        }
    }

    private var tokenField: some View {
        Group {
            if isSnapshot {
                Text(token.isEmpty ? "User token" : String(repeating: "•", count: min(token.count, 20)))
                    .foregroundColor(token.isEmpty ? Theme.muted : .white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                SecureField("User token", text: $token)
                    .textFieldStyle(.plain)
                    .onSubmit(connect)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
        .accessibilityLabel("ListenBrainz user token")
    }

    @ViewBuilder private var connectedRows: some View {
        let saved = listenBrainz.saved
        HStack(spacing: 8) {
            Text(saved.userName.map { "Connected as \($0)" } ?? "Connected")
                .foregroundColor(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            removeTokenButton
        }
        .font(.system(size: 12))
        .frame(height: 24)
        if !settings.recordHistory {
            line("Recording is off, so new plays are not sent.")
        }
        line(listenBrainzStatus, color: listenBrainz.problem == nil ? Theme.secondary : Theme.danger)
        if let fraction = listenBrainz.historyProgress, let h = saved.history {
            progressLine(historyProgressText(h), fraction: fraction)
        } else {
            actionRow(saved.history?.finished == nil ? "Send earlier listens" : "Send earlier listens again") {
                Task { await listenBrainz.sendHistory() }
            }
            if let h = saved.history, h.finished != nil {
                line("Sent \(HistorySettingsModel.count(h.sent)) earlier \(h.sent == 1 ? "listen" : "listens").")
            }
        }
    }

    private var listenBrainzStatus: String {
        let saved = listenBrainz.saved
        var parts: [String] = []
        if let problem = listenBrainz.problem {
            parts.append(problem)
            if let at = listenBrainz.retryAt { parts.append("Trying again \(Self.relative(at)).") }
        }
        if !saved.pending.isEmpty {
            parts.append("\(HistorySettingsModel.count(saved.pending.count)) waiting to send.")
        } else if parts.isEmpty {
            parts.append(saved.sent > 0
                ? "Sent \(HistorySettingsModel.count(saved.sent)) \(saved.sent == 1 ? "listen" : "listens")."
                : "Songs you play from now on are sent.")
        }
        if !saved.refused.isEmpty {
            parts.append("\(saved.refused.count) refused by ListenBrainz.")
        }
        return parts.joined(separator: " ")
    }

    private func historyProgressText(_ h: ListenBrainzSync.HistorySend) -> String {
        var text = "Sending earlier listens: \(HistorySettingsModel.count(h.sent)) sent"
        if let at = h.cursor?.startedAt {
            text += ", up to \(HistorySettingsModel.monthYear(Date(timeIntervalSince1970: TimeInterval(at) / 1000)))"
        }
        return text
    }

    private static func relative(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow.rounded()))
        if seconds < 60 { return "in \(max(1, seconds)) s" }
        return "in \((seconds + 59) / 60) min"
    }

    // MARK: Small parts

    /// Grey text under a setting. Wraps rather than being cut off.
    private func line(_ text: String, color: Color = Theme.secondary) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
            .padding(.bottom, 4)
    }

    /// Text and a thin bar for something under way.
    private func progressLine(_ text: String, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(Theme.accent)
                        .frame(width: geo.size.width * min(1, max(0, fraction ?? 0)))
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 4)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }

    /// A small text button on the same surface as the segmented controls.
    private func smallButton(_ title: String, color: Color = Theme.secondary,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle(color: color, hover: .white))
        .fixedSize()
    }


    /// Width of the keycap column, so both shortcut lists line up.
    private static let keyColumn: CGFloat = 64

    /// Full-width row that acts like a menu item: a faint surface on hover.
    private func actionRow(_ title: String, keys: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let keys {
                    KeyCap(keys)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle(color: .white, hover: .white, hoverFill: true))
        .padding(.horizontal, -8)
    }

    /// A grey line under a setting with a green link on the right. The text wraps rather
    /// than being cut off.
    private func note(_ text: String, action title: String, _ action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .foregroundColor(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(title, action: action)
                .buttonStyle(QuietButtonStyle(color: Theme.accent, hover: Theme.accentHover))
                .fixedSize()
        }
        .font(.system(size: 12))
        .padding(.vertical, 4)
        .frame(minHeight: 24)
        .padding(.bottom, 4)
    }

    private var divider: some View {
        Theme.hairline
            .frame(height: 1)
            .padding(.vertical, 8)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 0)
            content()
        }
        .frame(height: 32)
    }
}

// MARK: - Theme

private enum Theme {
    static let accent = Color(red: 0x1E / 255, green: 0xD7 / 255, blue: 0x60 / 255)
    static let accentHover = Color(red: 0x3B / 255, green: 0xE4 / 255, blue: 0x77 / 255)
    static let secondary = Color(white: 0.70)
    static let muted = Color(white: 0.50)
    static let hairline = Color.white.opacity(0.08)
    /// Deleting, and errors. A soft red that reads on the dark panel.
    static let danger = Color(red: 0xFF / 255, green: 0x7A / 255, blue: 0x70 / 255)
    static let ease = Animation.easeOut(duration: 0.15)
}

// MARK: - Controls

/// Two or more text segments; the selected one sits on a raised surface.
private struct SegmentedChoice<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var id: Value { value }
    }

    @Binding var selection: Value
    let options: [Option]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(Theme.ease) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.white.opacity(0.14))
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle(color: selected ? .white : Theme.secondary, hover: .white))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

/// A 30x18 switch: grey track when off, green when on, white knob that slides.
/// Drawn by hand so snapshots can render it. Also used by the welcome window.
struct GreenSwitch: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button {
            withAnimation(Theme.ease) { isOn.toggle() }
        } label: {
            ZStack {
                Capsule()
                    .fill(isOn ? Theme.accent : Color.white.opacity(0.22))
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .offset(x: isOn ? 6 : -6)
            }
            .frame(width: 30, height: 18)
            .contentShape(Capsule())
            .animation(Theme.ease, value: isOn)
        }
        .buttonStyle(SwitchButtonStyle())
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// "− 30 +" control for the menu bar title length.
struct LengthStepper: View {
    @Binding var value: Int

    private let range = AppSettings.titleLengthRange
    private static let step = AppSettings.titleLengthStep
    /// Lowest value the buttons go to: the first multiple of `step` in the range.
    static let lowest = (AppSettings.titleLengthRange.lowerBound + step - 1) / step * step

    /// The next multiple of 4 up or down from `value`, so any stored length (say 30)
    /// snaps onto 16, 20, 24, 28… Stays inside the settings range. Pure, for tests.
    static func stepped(_ value: Int, up: Bool) -> Int {
        let next = up ? (value / step + 1) * step : ((value + step - 1) / step - 1) * step
        return min(max(next, lowest), AppSettings.titleLengthRange.upperBound)
    }

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", label: "Shorter", enabled: value > Self.lowest) {
                value = Self.stepped(value, up: false)
            }
            Text("\(value)")
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 28)
                .accessibilityLabel("Title length \(value) characters")
            stepButton("plus", label: "Longer", enabled: value < range.upperBound) {
                value = Self.stepped(value, up: true)
            }
        }
        // Same surface as the segmented controls above it.
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
        .help("Longest menu bar title, in characters")
    }

    private func stepButton(_ symbol: String, label: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        // The style dims it when disabled.
        .buttonStyle(QuietButtonStyle(color: Theme.secondary, hover: .white, hoverFill: true))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// Plain two-column list: keys in muted grey, what they do in secondary grey.
private struct ShortcutList: View {
    let items: [(keys: String, action: String)]
    let keyWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(items[i].keys.split(separator: " ").map(String.init), id: \.self) { key in
                            KeyCap(key)
                        }
                    }
                    .frame(width: keyWidth, alignment: .leading)
                    Text(items[i].action)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.secondary)
                }
                .lineLimit(1)
                .frame(height: 24)
            }
        }
    }
}

/// One key or key combo on a small raised cap.
private struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.secondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 20, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.08)))
    }
}

/// The switch's button: no system chrome, our own focus ring.
private struct SwitchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SwitchButtonBody(configuration: configuration)
    }
}

private struct SwitchButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .focusOutline(Capsule().inset(by: -3), isFocused: isFocused)
    }
}

/// Plain text button: colour change on hover, optional faint surface, dims when pressed.
private struct QuietButtonStyle: ButtonStyle {
    var color: Color
    var hover: Color
    var hoverFill = false

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, color: color, hover: hover, hoverFill: hoverFill)
    }
}

private struct QuietButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let color: Color
    let hover: Color
    let hoverFill: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundColor(hovering && isEnabled ? hover : color)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(hoverFill && hovering && isEnabled ? 0.06 : 0))
            )
            .focusOutline(RoundedRectangle(cornerRadius: 4, style: .continuous), isFocused: isFocused)
            // Dimmed while it can't be used, like "Check for Updates…" during a check.
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Snapshot

extension SettingsView {
    /// Renders the panel to a PNG next to the player snapshot, for CI.
    @MainActor
    static func renderSnapshot(to url: URL) {
        let content = SettingsView(settings: snapshotSettings(), history: HistorySettingsModel.sample,
                                   listenBrainz: ListenBrainzSync.preview(connection: .noToken))
            .padding(16)
            .frame(width: 300)
            .background(PlayerTheme.fallback)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write("snapshot: settings render failed\n".data(using: .utf8)!)
            return
        }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The app's defaults, in their own suite so a snapshot never changes the user's settings.
    @MainActor
    static func snapshotSettings(_ edit: (AppSettings) -> Void = { _ in }) -> AppSettings {
        let suite = "tonearm.snapshot.settings"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let s = AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
        edit(s)
        return s
    }
}
