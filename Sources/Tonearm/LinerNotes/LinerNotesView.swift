import AppKit
import SwiftUI

/// The Liner Notes window: what you played in a week, month, year or all time. The first
/// screen answers the question (minutes, top artist, top song); the rest is below it.
struct LinerNotesView: View {
    @ObservedObject var model: LinerNotesModel
    @State private var sharing = false
    @State private var yearMenu = LinerMenu()
    @Environment(\.colorScheme) private var scheme

    static let gutter: CGFloat = 32
    static let maxContentWidth: CGFloat = 1120

    private var p: LinerPalette { LinerPalette(scheme) }
    private var tz: TimeZone { model.timeZone }

    var body: some View {
        ZStack(alignment: .top) {
            p.page
            content
        }
        .frame(minWidth: model.isSnapshot ? nil : LinerNotesWindow.minSize.width,
               minHeight: model.isSnapshot ? nil : LinerNotesWindow.minSize.height)
        .sheet(isPresented: $sharing) {
            ShareSheet(model: model) { sharing = false }
        }
    }

    @ViewBuilder private var content: some View {
        if model.importState != .idle {
            centered { ImportPanel(model: model) }
        } else {
            switch model.phase {
            case .loading:
                Color.clear
            case .empty:
                centered { EmptyHistory(model: model) }
            case .failed(let message):
                centered { failure(message) }
            case .ready:
                VStack(spacing: 0) {
                    header
                    Rectangle().fill(p.hairline).frame(height: 1)
                    if model.isSnapshot {
                        page
                    } else {
                        ScrollView(.vertical) { page }
                    }
                }
            }
        }
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c()
            .padding(48)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                Button(action: model.goBack) { Image(systemName: "chevron.left") }
                    .buttonStyle(LinerIconButtonStyle())
                    .disabled(!model.canGoBack)
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .help("Previous (⌘←)")
                    .accessibilityLabel("Previous period")
                Button(action: model.goForward) { Image(systemName: "chevron.right") }
                    .buttonStyle(LinerIconButtonStyle())
                    .disabled(!model.canGoForward)
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .help("Next (⌘→)")
                    .accessibilityLabel("Next period")
            }
            Button(action: showYearMenu) {
                HStack(spacing: 6) {
                    Text(LinerFormat.title(model.period, timeZone: tz))
                        .font(LinerType.serif(22))
                        .foregroundColor(p.primary)
                        .lineLimit(1)
                        .fixedSize()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(p.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose a year")
            .accessibilityLabel("Period: \(LinerFormat.title(model.period, timeZone: tz)). Choose a year")
            Spacer(minLength: 16)
            KindPicker(selection: model.period.kind) { model.select(kind: $0) }
            Button(action: model.chooseImport) { Image(systemName: "square.and.arrow.down") }
                .buttonStyle(LinerIconButtonStyle())
                .keyboardShortcut("o", modifiers: .command)
                .help("Import Spotify history (⌘O)")
                .accessibilityLabel("Import Spotify history")
            Button("Share") { sharing = true }
                .buttonStyle(LinerButtonStyle(kind: .primary))
                .disabled(model.stats.map { $0.music.ms == 0 } ?? true)
                .help("Make an image of this period to save or send")
        }
        .padding(.horizontal, Self.gutter - 6)
        .frame(height: 56)
    }

    private func showYearMenu() {
        let current: Int? = {
            if case .year(let y) = model.period { return y }
            return model.period.days?.lowerBound.year
        }()
        var items: [(String, Int, Bool)?] = model.years.reversed().map { ("\($0)", $0, $0 == current) }
        items.append(nil)
        items.append(("All time", 0, model.period == .allTime))
        yearMenu.show(items) { tag in
            if tag == 0 { model.select(.allTime) } else { model.select(year: tag) }
        }
    }

    // MARK: Page

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let s = model.stats {
                if s.music.ms == 0 {
                    emptyPeriod(s)
                } else {
                    hero(s)
                    ListeningChart(stats: s, timeZone: tz, palette: p, today: model.today)
                        .padding(.top, 48)
                    HStack(alignment: .top, spacing: 48) {
                        clock(s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        facts(s)
                            .frame(width: 300)
                    }
                    .padding(.top, 48)
                    HStack(alignment: .top, spacing: 48) {
                        rankedList("Top artists", s.music.topArtists, kind: .artist)
                        rankedList("Top songs", s.music.topTracks, kind: .song)
                    }
                    .padding(.top, 48)
                    albumShelf(s.music.topAlbums)
                        .padding(.top, 48)
                }
            }
        }
        .padding(.horizontal, Self.gutter)
        .padding(.top, 28)
        .padding(.bottom, 48)
        .frame(maxWidth: Self.maxContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .opacity(model.loadingStats ? 0.55 : 1)
        .animation(PlayerTheme.medium, value: model.loadingStats)
    }

    // MARK: Hero

    /// The sleeve: the top album's cover and colors, the minutes, the counts, the top artist
    /// and the top song. Everything a glance should answer.
    private func hero(_ s: Stats) -> some View {
        let sleeve = model.sleeve
        let secondary = Color.white.opacity(SleeveColors.secondaryOpacity)
        let album = s.music.topAlbums.first
        return HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 12) {
                ArtTile(image: model.topAlbumImage, name: model.topAlbumName, size: 200, radius: 6)
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                if let album {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Top album").font(.system(size: 12)).foregroundColor(secondary)
                        WordClampedText(text: album.name, font: .system(size: 13, weight: .medium), lines: 2,
                                        color: .white)
                        Text(LinerFormat.meta(album)).font(.system(size: 12).monospacedDigit()).foregroundColor(secondary)
                    }
                    .frame(width: 200, alignment: .leading)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                // The counts sit beside the minutes when there is room, under them when not.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        minutes(s, shrinks: false)
                        Spacer(minLength: 0)
                        counts(s, columns: 2)
                            .padding(.top, 20)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        minutes(s, shrinks: true)
                        counts(s, columns: 4)
                    }
                }
                Rectangle().fill(Color.white.opacity(0.16)).frame(height: 1)
                    .padding(.vertical, 24)
                HStack(alignment: .top, spacing: 32) {
                    if let artist = s.music.topArtists.first {
                        heroPick("Top artist", artist.name, LinerFormat.meta(artist))
                    }
                    if let song = s.music.topTracks.first {
                        heroPick("Top song", song.name,
                                 [song.artist, LinerFormat.minutesText(song.ms)].compactMap { $0 }.joined(separator: " · "))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(32)
        .background(sleeve.gradient)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func heroPick(_ label: String, _ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(SleeveColors.secondaryOpacity))
            WordClampedText(text: name, font: LinerType.serif(26), lines: 2, color: .white)
            WordClampedText(text: detail, font: .system(size: 13).monospacedDigit(), lines: 1,
                            color: .white.opacity(SleeveColors.secondaryOpacity))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func minutes(_ s: Stats, shrinks: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Minutes listened")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(SleeveColors.secondaryOpacity))
            Text(LinerFormat.number(LinerFormat.minutes(s.music.ms)))
                .font(LinerType.serif(72))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(shrinks ? 0.5 : 1)
                .fixedSize(horizontal: !shrinks, vertical: false)
            Text("\(LinerFormat.hours(s.music.ms)) of music \(LinerFormat.inPeriod(model.period, timeZone: tz))")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(SleeveColors.secondaryOpacity))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Plays, songs, artists and albums on the sleeve, in two or four columns.
    private func counts(_ s: Stats, columns: Int) -> some View {
        let all = [
            (s.music.listens, s.music.listens == 1 ? "Play" : "Plays"),
            (s.music.uniqueTracks, s.music.uniqueTracks == 1 ? "Song" : "Songs"),
            (s.music.uniqueArtists, s.music.uniqueArtists == 1 ? "Artist" : "Artists"),
            (s.music.uniqueAlbums, s.music.uniqueAlbums == 1 ? "Album" : "Albums"),
        ]
        return Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 16) {
            ForEach(Array(stride(from: 0, to: all.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(start..<min(start + columns, all.count), id: \.self) { i in
                        count(all[i].0, all[i].1)
                    }
                }
            }
        }
        .fixedSize()
    }

    private func count(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LinerFormat.number(n))
                .font(LinerType.serif(24))
                .foregroundColor(.white)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(SleeveColors.secondaryOpacity))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Clock and facts

    private func sectionTitle(_ title: String, _ detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(p.primary)
            Spacer(minLength: 16)
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(p.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func clock(_ s: Stats) -> some View {
        let clock = ListeningClock(heatmap: s.music.heatmap, palette: p)
        return VStack(alignment: .leading, spacing: 16) {
            sectionTitle("When you listen")
            clock
            Text(clock.caption)
                .font(.system(size: 12))
                .foregroundColor(p.secondary)
        }
    }

    private func facts(_ s: Stats) -> some View {
        let withYear = model.period == .allTime
        var rows: [(String, String, String?)] = []
        if let streak = s.music.longestStreak {
            rows.append(("Longest streak", streak.days == 1 ? "1 day" : "\(LinerFormat.number(streak.days)) days",
                         LinerFormat.span(streak.start, streak.end, timeZone: tz, withYear: withYear)))
        }
        if let busiest = s.music.busiestDay {
            rows.append(("Busiest day", LinerFormat.minutesText(busiest.ms),
                         LinerFormat.day(busiest.day, timeZone: tz, withYear: withYear)))
        }
        // Over all time every artist is new, so the row would only repeat the artist count.
        let newOnes = s.music.newArtists
        if model.period != .allTime {
            rows.append(("New artists", LinerFormat.number(newOnes.count),
                         newOnes.top.isEmpty ? nil : newOnes.top.prefix(3).map(\.name).joined(separator: ", ")))
        }
        if s.podcasts.ms > 0 {
            rows.append(("Podcasts", LinerFormat.minutesText(s.podcasts.ms), s.podcasts.topShows.first?.name))
        }
        return VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Notes")
                .padding(.bottom, 4)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                VStack(alignment: .leading, spacing: 0) {
                    if i > 0 { Rectangle().fill(p.hairline).frame(height: 1) }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.0)
                                .font(.system(size: 13))
                                .foregroundColor(p.primary)
                            if let detail = row.2 {
                                WordClampedText(text: detail, font: .system(size: 12), lines: 2, color: p.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(row.1)
                            .font(LinerType.serif(20))
                            .foregroundColor(p.primary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.vertical, 12)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Top lists

    private enum ListKind { case artist, song, album }

    /// A ranked list: rank, cover, name (and artist), and minutes and plays in a right-hand column.
    private func rankedList(_ title: String, _ items: [Stats.Item], kind: ListKind) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle(title)
                .padding(.bottom, 12)
            if items.isEmpty {
                Text("None yet").font(.system(size: 13)).foregroundColor(p.muted).padding(.vertical, 8)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                HStack(alignment: .center, spacing: 12) {
                    Text("\(i + 1)")
                        .font(LinerType.mono(12))
                        .foregroundColor(p.muted)
                        .frame(width: 20, alignment: .trailing)
                    ArtTile(image: image(item, kind), name: item.name, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        WordClampedText(text: item.name, font: .system(size: 13, weight: .medium), lines: 2,
                                        color: p.primary)
                        if let artist = item.artist, !artist.isEmpty {
                            WordClampedText(text: artist, font: .system(size: 12), lines: 1, color: p.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(LinerFormat.minutesText(item.ms))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundColor(p.primary)
                        Text(LinerFormat.plays(item.listens))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundColor(p.muted)
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
                .frame(minHeight: 48)
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The top albums as a shelf of covers, five to a row.
    private func albumShelf(_ items: [Stats.Item]) -> some View {
        let perRow = 5
        let rows = stride(from: 0, to: items.count, by: perRow).map { Array(items[$0..<min($0 + perRow, items.count)]) }
        return VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Top albums")
                .padding(.bottom, 16)
            if items.isEmpty {
                Text("None yet").font(.system(size: 13)).foregroundColor(p.muted)
            }
            VStack(alignment: .leading, spacing: 28) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    HStack(alignment: .top, spacing: 24) {
                        ForEach(0..<perRow, id: \.self) { j in
                            if j < row.count {
                                albumCell(row[j], rank: r * perRow + j + 1)
                            } else {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func albumCell(_ item: Stats.Item, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SquareArt(image: model.image(album: item), name: item.name, radius: 6)
                .padding(.bottom, 10)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(rank)")
                    .font(LinerType.mono(12))
                    .foregroundColor(p.muted)
                WordClampedText(text: item.name, font: .system(size: 13, weight: .medium), lines: 2, color: p.primary)
            }
            if let artist = item.artist, !artist.isEmpty {
                WordClampedText(text: artist, font: .system(size: 12), lines: 1, color: p.secondary)
            }
            Text(LinerFormat.meta(item))
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(p.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func image(_ item: Stats.Item, _ kind: ListKind) -> NSImage? {
        switch kind {
        case .artist: return model.image(artist: item.name)
        case .song: return model.image(song: item)
        case .album: return model.image(album: item)
        }
    }

    // MARK: Empty and failed

    private func emptyPeriod(_ s: Stats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nothing played \(LinerFormat.inPeriod(model.period, timeZone: tz))")
                .font(LinerType.serif(28))
                .foregroundColor(p.primary)
            Text(emptyPeriodDetail(s))
                .font(.system(size: 14))
                .foregroundColor(p.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let target = emptyPeriodTarget {
                Button("Show \(String(target))") { model.select(.year(target)) }
                    .buttonStyle(LinerButtonStyle())
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.top, 72)
        .frame(maxWidth: .infinity)
    }

    /// True when the period ends before the first year with listens.
    private var beforeHistory: Bool {
        guard let first = model.years.first, let days = model.period.days else { return false }
        return days.upperBound <= LocalDay(year: first, month: 1, day: 1)
    }

    /// The year to offer instead: the first one when this period is before it, else the latest.
    private var emptyPeriodTarget: Int? {
        let target = beforeHistory ? model.years.first : model.years.last
        guard let target, model.period != .year(target) else { return nil }
        return target
    }

    private func emptyPeriodDetail(_ s: Stats) -> String {
        if s.podcasts.ms > 0 {
            return "Only podcasts: \(LinerFormat.minutesText(s.podcasts.ms)). Liner Notes counts music."
        }
        if beforeHistory, let first = model.years.first {
            return "Your history starts in \(first)."
        }
        return AppSettings.shared.recordHistory
            ? "Tonearm writes down what you play in Spotify while it runs. Pick another period, or import your Spotify history for the years before."
            : "Record listening is off in Settings › History, so new plays aren’t written down. Older periods still show what you imported."
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Can’t read your listening history")
                .font(LinerType.serif(28))
                .foregroundColor(p.primary)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(p.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { Task { await model.refresh() } }
                .buttonStyle(LinerButtonStyle())
                .padding(.top, 8)
        }
        .frame(maxWidth: 480, alignment: .leading)
    }
}

/// No history at all: what Liner Notes is, and how to bring in years of it in a minute.
struct EmptyHistory: View {
    @ObservedObject var model: LinerNotesModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = LinerPalette(scheme)
        VStack(alignment: .leading, spacing: 0) {
            SleeveDrawing()
                .padding(.bottom, 32)
            Text("Your listening, kept on this Mac")
                .font(LinerType.serif(32))
                .foregroundColor(p.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(AppSettings.shared.recordHistory
                 ? "Tonearm writes down what you play in Spotify. To see the years before Tonearm, import the history Spotify keeps for you."
                 : "Record listening is off in Settings › History, so Tonearm isn’t writing down what you play. You can still import the history Spotify keeps for you.")
                .font(.system(size: 14))
                .foregroundColor(p.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            VStack(alignment: .leading, spacing: 8) {
                step(1, "On spotify.com, open Account › Privacy, and under Download your data ask for your extended streaming history.", p)
                step(2, "Spotify emails you a .zip, in a few days or up to a month. Choose it here.", p)
            }
            .padding(.top, 20)
            Button("Import your Spotify history", action: model.chooseImport)
                .buttonStyle(LinerButtonStyle(kind: .primary, large: true))
                .keyboardShortcut("o", modifiers: .command)
                .padding(.top, 28)
            Text("The file is read on this Mac. Nothing is uploaded.")
                .font(.system(size: 12))
                .foregroundColor(p.muted)
                .padding(.top, 12)
        }
        .frame(maxWidth: 500, alignment: .leading)
    }

    private func step(_ n: Int, _ text: String, _ p: LinerPalette) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(LinerType.mono(12))
                .foregroundColor(p.muted)
                .frame(width: 12, alignment: .leading)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(p.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A record half out of its sleeve, in the colors of Tonearm's icon.
struct SleeveDrawing: View {
    var size: CGFloat = 112

    var body: some View {
        ZStack(alignment: .leading) {
            TonearmMark(size: size * 0.94)
                .offset(x: size * 0.5)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(LinerPalette.rgb(0x2C2C2F))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(Color.white.opacity(0.22)).frame(width: size * 0.42, height: 3)
                        Capsule().fill(Color.white.opacity(0.12)).frame(width: size * 0.28, height: 3)
                    }
                    .padding(size * 0.12)
                }
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
        .frame(width: size * 1.5, height: size, alignment: .leading)
        .accessibilityHidden(true)
    }
}

/// Import progress, then what it brought.
struct ImportPanel: View {
    @ObservedObject var model: LinerNotesModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = LinerPalette(scheme)
        VStack(alignment: .leading, spacing: 0) {
            switch model.importState {
            case .idle:
                EmptyView()
            case .running(let done, let total, let rows):
                Text("Importing your Spotify history")
                    .font(LinerType.serif(28))
                    .foregroundColor(p.primary)
                ProgressLine(value: total > 0 ? Double(done) / Double(total) : 0, palette: p)
                    .padding(.top, 24)
                Text(total > 0
                     ? "File \(min(done + 1, total)) of \(total) · \(LinerFormat.number(rows)) entries read"
                     : "Opening the export")
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundColor(p.secondary)
                    .padding(.top, 12)
            case .finished(let r, let plays):
                Text(HistoryWords.importHeadline(r, plays: plays))
                    .font(LinerType.serif(28))
                    .foregroundColor(p.primary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(HistoryWords.importLines(r, plays: plays, timeZone: model.timeZone), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 13))
                            .foregroundColor(p.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 12)
                Button("Show Liner Notes", action: model.dismissImport)
                    .buttonStyle(LinerButtonStyle(kind: .primary, large: true))
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 28)
            case .failed(let message):
                Text("Couldn’t import that")
                    .font(LinerType.serif(28))
                    .foregroundColor(p.primary)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(p.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                HStack(spacing: 12) {
                    Button("Choose another file", action: model.chooseImport)
                        .buttonStyle(LinerButtonStyle(kind: .primary, large: true))
                    Button("Cancel", action: model.dismissImport)
                        .buttonStyle(LinerButtonStyle(large: true))
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 28)
            }
        }
        .frame(width: 440, alignment: .leading)
    }
}

/// A thin determinate bar. The system's draws with AppKit, which snapshots can't render.
struct ProgressLine: View {
    var value: Double
    var palette: LinerPalette

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.raised)
                Capsule().fill(palette.accent)
                    .frame(width: max(4, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 4)
        .animation(PlayerTheme.medium, value: value)
        .accessibilityElement()
        .accessibilityLabel("Import progress")
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}
