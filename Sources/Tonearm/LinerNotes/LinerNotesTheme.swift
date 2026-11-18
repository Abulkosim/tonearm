import AppKit
import SwiftUI

/// Colors for the Liner Notes window, in light and dark. Neutral greys like the player, and
/// one accent: the orange of the record label in Tonearm's icon. The color in the window
/// comes from the music itself, in the sleeve at the top.
struct LinerPalette {
    var page: Color
    /// Selected segment, hovered row, inputs.
    var raised: Color
    var hairline: Color
    var primary: Color
    var secondary: Color
    var muted: Color
    /// Chart highlight and the listening clock.
    var accent: Color
    /// Bars that are not the highlight.
    var bar: Color
    /// Empty cells of the listening clock.
    var emptyCell: Color
    /// Filled button: the primary text color as a surface.
    var buttonFill: Color
    var buttonText: Color

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            page = PlayerTheme.base
            raised = Color.white.opacity(0.08)
            hairline = Color.white.opacity(0.08)
            primary = Self.rgb(0xF2F2F2)
            secondary = PlayerTheme.textSecondary
            muted = Self.rgb(0x8C8C8C)
            accent = Self.rgb(0xE8863F)
            bar = Color.white.opacity(0.26)
            emptyCell = Color.white.opacity(0.05)
            buttonFill = Self.rgb(0xF2F2F2)
            buttonText = Self.rgb(0x121212)
        } else {
            page = Self.rgb(0xFAFAFA)
            raised = Color.black.opacity(0.05)
            hairline = Color.black.opacity(0.08)
            primary = Self.rgb(0x171717)
            secondary = Self.rgb(0x525252)
            muted = Self.rgb(0x6E6E6E)
            accent = Self.rgb(0xD9762F)
            bar = Color.black.opacity(0.2)
            emptyCell = Color.black.opacity(0.045)
            buttonFill = Self.rgb(0x171717)
            buttonText = Self.rgb(0xFAFAFA)
        }
    }

    static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// Type for Liner Notes. The big figures and names are set in the system serif, like the
/// printed notes in a record sleeve; everything else is the system font.
enum LinerType {
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Numbers, minutes and dates, formatted one way across the window and the share card.
enum LinerFormat {
    static func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Whole minutes, rounded to the nearest.
    static func minutes(_ ms: Int64) -> Int { Int((Double(ms) / 60_000).rounded()) }

    static func minutesText(_ ms: Int64) -> String { "\(number(minutes(ms))) min" }

    /// "12 min", or "under a minute" for less than one.
    static func roughMinutes(_ ms: Int64) -> String { ms < 60_000 ? "under a minute" : minutesText(ms) }

    static func plays(_ n: Int) -> String { n == 1 ? "1 play" : "\(number(n)) plays" }

    /// "1,204 min · 312 plays"
    static func meta(_ item: Stats.Item) -> String { "\(minutesText(item.ms)) · \(plays(item.listens))" }

    /// "687 hours", or "41 minutes" under an hour.
    static func hours(_ ms: Int64) -> String {
        let h = Int(Double(ms) / 3_600_000)
        if h >= 1 { return h == 1 ? "1 hour" : "\(number(h)) hours" }
        let m = minutes(ms)
        return m == 1 ? "1 minute" : "\(number(m)) minutes"
    }

    private static func formatter(_ template: String, _ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.timeZone = tz
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    /// "Nov 17 – 23, 2025", "November 2025", "2024", "All time".
    static func title(_ period: Period, timeZone tz: TimeZone) -> String {
        switch period {
        case .week:
            guard let days = period.days else { return "" }
            let f = DateIntervalFormatter()
            f.timeZone = tz
            f.dateTemplate = "MMMdy"
            return f.string(from: days.lowerBound.date(in: tz), to: days.upperBound.adding(days: -1).date(in: tz))
        case .month(let y, let m):
            return formatter("MMMMy", tz).string(from: LocalDay(year: y, month: m, day: 1).date(in: tz))
        case .year(let y):
            return "\(y)"
        case .allTime:
            return "All time"
        }
    }

    /// For sentences: "this week of Nov 17", "in November 2025", "in 2024", "so far".
    static func inPeriod(_ period: Period, timeZone tz: TimeZone) -> String {
        switch period {
        case .week: return "in the week of \(formatter("MMMd", tz).string(from: period.days!.lowerBound.date(in: tz)))"
        case .month, .year: return "in \(title(period, timeZone: tz))"
        case .allTime: return "so far"
        }
    }

    /// "Sat, Jun 14", with the year when `withYear`.
    static func day(_ day: LocalDay, timeZone tz: TimeZone, withYear: Bool = false) -> String {
        formatter(withYear ? "EEEMMMdy" : "EEEMMMd", tz).string(from: day.date(in: tz))
    }

    /// "Mar 3 – Apr 12", with the year when `withYear`.
    static func span(_ start: LocalDay, _ end: LocalDay, timeZone tz: TimeZone, withYear: Bool = false) -> String {
        if start == end { return formatter(withYear ? "MMMdy" : "MMMd", tz).string(from: start.date(in: tz)) }
        let f = DateIntervalFormatter()
        f.timeZone = tz
        f.dateTemplate = withYear ? "MMMdy" : "MMMd"
        return f.string(from: start.date(in: tz), to: end.date(in: tz))
    }

    /// "9 PM" or "21", as the Mac shows hours.
    static func hour(_ h: Int) -> String {
        let f = formatter("j", TimeZone(identifier: "UTC")!)
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(h * 3600)))
    }

    /// Short weekday names, Monday first.
    static var weekdays: [String] {
        let symbols = DateFormatter().shortWeekdaySymbols ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return Array(symbols[1...]) + [symbols[0]]
    }

    /// Full weekday names, Monday first.
    static var weekdayNames: [String] {
        let symbols = DateFormatter().weekdaySymbols ?? ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
                                                         "Friday", "Saturday"]
        return Array(symbols[1...]) + [symbols[0]]
    }
}

extension Period {
    /// The period after this one. All time has none.
    var next: Period? {
        switch self {
        case .week(let d): return .week(d.adding(days: 7))
        case .month(let y, let m): return m == 12 ? .month(year: y + 1, month: 1) : .month(year: y, month: m + 1)
        case .year(let y): return .year(y + 1)
        case .allTime: return nil
        }
    }

    var kind: Kind {
        switch self {
        case .week: return .week
        case .month: return .month
        case .year: return .year
        case .allTime: return .allTime
        }
    }

    /// The period of `kind` that holds `day`.
    static func of(_ kind: Kind, containing day: LocalDay) -> Period {
        switch kind {
        case .week: return .week(day)
        case .month: return .month(year: day.year, month: day.month)
        case .year: return .year(day.year)
        case .allTime: return .allTime
        }
    }
}

extension Period.Kind {
    var label: String {
        switch self {
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        case .allTime: return "All time"
        }
    }
}
