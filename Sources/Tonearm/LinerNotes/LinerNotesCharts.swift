import Accessibility
import Charts
import SwiftUI

/// Minutes over the period: one bar a day for a week, month or year, one a month for all
/// time. The busiest bar is the accent; the rest are neutral. Hovering a bar shows its value.
struct ListeningChart: View {
    struct Bar: Identifiable, Equatable {
        var date: Date
        var ms: Int64
        var id: Date { date }
    }

    var stats: Stats
    var timeZone: TimeZone
    var palette: LinerPalette
    var today: LocalDay
    @State private var hovered: Date?

    static func daysSoFar(_ daily: [Stats.DayTotal], today: LocalDay) -> Int {
        daily.reduce(0) { $0 + ($1.day <= today ? 1 : 0) }
    }

    enum Unit { case day, month }

    var unit: Unit { stats.period == "all" ? .month : .day }

    var title: String { unit == .day ? "Minutes per day" : "Minutes per month" }

    /// Days of the period, or months of all time.
    var bars: [Bar] {
        let daily = stats.music.daily
        guard unit == .month else { return daily.map { Bar(date: $0.day.date(in: timeZone), ms: $0.ms) } }
        var months: [(key: Int, ms: Int64)] = []
        for d in daily {
            let key = d.day.year * 12 + d.day.month - 1
            if months.last?.key == key { months[months.count - 1].ms += d.ms } else { months.append((key, d.ms)) }
        }
        return months.map { Bar(date: LocalDay(year: $0.key / 12, month: $0.key % 12 + 1, day: 1).date(in: timeZone),
                                ms: $0.ms) }
    }

    /// "Average 113 min a day" over the days of the period so far: in this week, month or year,
    /// the days still to come don't count.
    var average: String {
        let days = Self.daysSoFar(stats.music.daily, today: today)
        guard days > 0 else { return "" }
        let perDay = Double(stats.music.ms) / Double(days) / 60_000
        return "Average \(LinerFormat.number(Int(perDay.rounded()))) min a day"
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.firstWeekday = 2
        return c
    }

    var body: some View {
        let data = bars
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(palette.primary)
                Spacer(minLength: 16)
                Text(hoverText(data) ?? average)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(hovered == nil ? palette.secondary : palette.primary)
                    .lineLimit(1)
            }
            chart(data)
                .frame(height: 180)
        }
    }

    private func chart(_ data: [Bar]) -> some View {
        let peak = data.max { $0.ms < $1.ms }?.date
        let thin = data.count > 62
        return Chart(data) { bar in
            BarMark(
                x: .value("Date", bar.date, unit: unit == .day ? .day : .month),
                y: .value("Minutes", Double(bar.ms) / 60_000),
                width: thin ? .ratio(0.8) : .ratio(0.62)
            )
            .foregroundStyle(bar.date == peak || bar.date == hovered ? palette.accent : palette.bar)
            .cornerRadius(thin ? 1 : 3)
            // The busiest bar says how busy, so the one number that matters needs no hover.
            .annotation(position: .top, spacing: 4) {
                if bar.date == peak && hovered == nil {
                    Text(LinerFormat.minutesText(bar.ms))
                        .font(LinerType.mono(10))
                        .foregroundColor(palette.secondary)
                        .fixedSize()
                }
            }
        }
        // Fit the tallest bar instead of rounding the axis up to the next round number.
        .chartYScale(domain: 0...max(1, Double(data.map(\.ms).max() ?? 0) / 60_000 * 1.16))
        .chartXAxis {
            AxisMarks(values: axisValues(count: data.count)) { value in
                axisLabel(value, axisTemplate(count: data.count), last: data.last?.date)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(palette.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(LinerFormat.number(Int(v))).font(LinerType.mono(10)).foregroundColor(palette.muted)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let x = point.x - geo[proxy.plotAreaFrame].origin.x
                            if let date: Date = proxy.value(atX: x) { hovered = nearest(date, in: data) }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .environment(\.calendar, calendar)
        .environment(\.timeZone, timeZone)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilitySummary(data))
        .accessibilityChartDescriptor(self)
    }

    private func dateText(_ date: Date, _ template: String) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    private func hoverText(_ data: [Bar]) -> String? {
        guard let hovered, let bar = data.first(where: { $0.date == hovered }) else { return nil }
        return "\(dateText(bar.date, unit == .day ? "EEEMMMdy" : "MMMMy")) · \(LinerFormat.minutesText(bar.ms))"
    }

    private func axisTemplate(count: Int) -> String {
        switch (unit, count) {
        case (.month, _): return "y"
        case (.day, ...7): return "EEE"
        case (.day, ...31): return "d"
        default: return "MMM"
        }
    }

    private func axisValues(count: Int) -> AxisMarkValues {
        switch (unit, count) {
        case (.month, _): return .stride(by: .year)
        case (.day, ...7): return .stride(by: .day)
        case (.day, ...31): return .stride(by: .day, count: 7)
        default: return .stride(by: .month)
        }
    }

    /// Weekday labels sit under their bar; dates, months and years start at their tick. A tick
    /// past the last bar (next year's, on the all-time chart) gets no label: it would be cut.
    private func axisLabel(_ value: AxisValue, _ template: String, last: Date?) -> some AxisMark {
        AxisValueLabel(centered: stats.music.daily.count <= 7) {
            if let date = value.as(Date.self), date <= (last ?? date) {
                Text(dateText(date, template)).font(LinerType.mono(10)).foregroundColor(palette.muted)
            }
        }
    }

    private func nearest(_ date: Date, in data: [Bar]) -> Date? {
        data.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.date
    }

    func accessibilitySummary(_ data: [Bar]) -> String {
        guard let peak = data.max(by: { $0.ms < $1.ms }) else { return "No listening" }
        let day = dateText(peak.date, unit == .day ? "MMMMd" : "MMMMy")
        return "\(average). Most on \(day), \(LinerFormat.minutesText(peak.ms))."
    }
}

/// VoiceOver's audio graph and data table of the bars: every day (or month) and its minutes.
extension ListeningChart: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let data = bars
        let names = data.map { dateText($0.date, unit == .day ? "EEEMMMdy" : "MMMMy") }
        let most = Double(data.map(\.ms).max() ?? 0) / 60_000
        let x = AXCategoricalDataAxisDescriptor(title: unit == .day ? "Day" : "Month", categoryOrder: names)
        let y = AXNumericDataAxisDescriptor(title: "Minutes", range: 0...max(1, most), gridlinePositions: []) {
            "\(LinerFormat.number(Int($0.rounded()))) min"
        }
        let points = zip(names, data).map { name, bar in
            AXDataPoint(x: name, y: Double(bar.ms) / 60_000, additionalValues: [],
                        label: "\(name), \(LinerFormat.minutesText(bar.ms))")
        }
        let series = AXDataSeriesDescriptor(name: "Minutes", isContinuous: false, dataPoints: points)
        return AXChartDescriptor(title: title, summary: accessibilitySummary(data), xAxis: x, yAxis: y,
                                 additionalAxes: [], series: [series])
    }
}

/// When you listen: seven rows, Monday first, of 24 hours. Darker orange is more minutes.
struct ListeningClock: View {
    var heatmap: [[Int64]]
    var palette: LinerPalette

    static let gap: CGFloat = 3
    static let labelWidth: CGFloat = 40

    var peak: (day: Int, hour: Int)? {
        var best: (Int, Int)?
        var most: Int64 = 0
        for d in 0..<min(7, heatmap.count) {
            for h in 0..<min(24, heatmap[d].count) where heatmap[d][h] > most {
                most = heatmap[d][h]
                best = (d, h)
            }
        }
        return best
    }

    /// Opacity of a cell: 0.12 for the quietest hour with listening, 1 for the busiest.
    static func shade(_ v: Double, least: Double, most: Double) -> Double {
        guard most > least else { return 1 }
        let t = (v - least) / (most - least)
        return 0.12 + 0.88 * t * t
    }

    /// "Most often on Saturday around 9 PM"
    var caption: String {
        guard let p = peak else { return "" }
        return "Most often on \(LinerFormat.weekdayNames[p.day]) around \(LinerFormat.hour(p.hour))"
    }

    var body: some View {
        // Shade from the quietest hour that has any listening to the busiest one, so the shape
        // of a week shows even when every hour has some.
        let filled = heatmap.flatMap { $0 }.filter { $0 > 0 }.map(Double.init)
        let most = filled.max() ?? 0, least = filled.min() ?? 0
        let names = LinerFormat.weekdays
        VStack(alignment: .leading, spacing: 8) {
            ClockGrid(gap: Self.gap, labelWidth: Self.labelWidth) {
                ForEach(0..<7, id: \.self) { d in
                    Text(names[d])
                        .font(.system(size: 11))
                        .foregroundColor(palette.muted)
                        .lineLimit(1)
                }
                ForEach(0..<(7 * 24), id: \.self) { i in
                    let d = i / 24, h = i % 24
                    let v = d < heatmap.count && h < heatmap[d].count ? Double(heatmap[d][h]) : 0
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(v > 0 ? palette.accent.opacity(Self.shade(v, least: least, most: most))
                                    : palette.emptyCell)
                }
            }
            HStack(spacing: Self.gap) {
                ForEach(0..<24, id: \.self) { h in
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 14)
                        .overlay(alignment: .leading) {
                            if h % 6 == 0 {
                                Text(LinerFormat.hour(h))
                                    .font(LinerType.mono(10))
                                    .foregroundColor(palette.muted)
                                    .fixedSize()
                            }
                        }
                }
            }
            .padding(.leading, Self.labelWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Listening by weekday and hour")
        .accessibilityValue(caption)
        .accessibilityChartDescriptor(self)
    }
}

/// VoiceOver's audio graph and data table of the clock: one series a weekday, minutes by hour.
extension ListeningClock: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let hours = (0..<24).map(LinerFormat.hour)
        let days = LinerFormat.weekdayNames
        var most: Int64 = 0
        let series = (0..<7).map { d in
            let day = d < days.count ? days[d] : "\(d + 1)"
            return AXDataSeriesDescriptor(name: day, isContinuous: false, dataPoints: (0..<24).map { h in
                let ms = d < heatmap.count && h < heatmap[d].count ? heatmap[d][h] : 0
                most = max(most, ms)
                return AXDataPoint(x: hours[h], y: Double(ms) / 60_000, additionalValues: [],
                                   label: "\(day) \(hours[h]), \(LinerFormat.minutesText(ms))")
            })
        }
        let x = AXCategoricalDataAxisDescriptor(title: "Hour", categoryOrder: hours)
        let y = AXNumericDataAxisDescriptor(title: "Minutes", range: 0...max(1, Double(most) / 60_000),
                                            gridlinePositions: []) {
            "\(LinerFormat.number(Int($0.rounded()))) min"
        }
        return AXChartDescriptor(title: "Listening by weekday and hour", summary: caption, xAxis: x, yAxis: y,
                                 additionalAxes: [], series: series)
    }
}

/// Seven row labels, then 7 x 24 square cells, sized from the width it is offered. Square
/// cells from `aspectRatio` grow without bound when the height is open, as in a scroll view.
private struct ClockGrid: Layout {
    var gap: CGFloat
    var labelWidth: CGFloat

    static let maxCell: CGFloat = 26

    /// Stacks probe with an infinite width; the cell size is capped so the height never is.
    private func cell(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return Self.maxCell }
        return min(Self.maxCell, max(4, (width - labelWidth - gap * 23) / 24))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = labelWidth + 24 * 16 + 23 * gap
        let width = proposal.width.map { $0.isFinite ? $0 : ideal } ?? ideal
        let c = cell(width)
        return CGSize(width: width, height: 7 * c + 6 * gap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 7 + 7 * 24 else { return }
        let c = cell(bounds.width)
        for d in 0..<7 {
            let y = bounds.minY + CGFloat(d) * (c + gap) + c / 2
            subviews[d].place(at: CGPoint(x: bounds.minX, y: y), anchor: .leading,
                              proposal: ProposedViewSize(width: labelWidth - 8, height: c))
        }
        for i in 0..<(7 * 24) {
            let d = i / 24, h = i % 24
            let origin = CGPoint(x: bounds.minX + labelWidth + CGFloat(h) * (c + gap),
                                 y: bounds.minY + CGFloat(d) * (c + gap))
            subviews[7 + i].place(at: origin, proposal: ProposedViewSize(width: c, height: c))
        }
    }
}
