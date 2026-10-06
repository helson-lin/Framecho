//
//  CaptureLibraryDateSections.swift
//  Framecho
//
//  Groups the Library's time-sorted captures under date headings. Kept free of
//  app types so scripts/check-library-date-sections.swift can exercise it.
//

import Foundation

nonisolated enum CaptureLibraryDateSection: Hashable, Sendable {
    case today
    case yesterday
    case previousSevenDays
    case month(year: Int, month: Int)

    /// Captures dated in the future (a changed clock) count as today.
    init(date: Date, now: Date, calendar: Calendar) {
        let startOfToday = calendar.startOfDay(for: now)
        if date >= startOfToday {
            self = .today
        } else if let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
                  date >= startOfYesterday {
            self = .yesterday
        } else if let startOfWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday),
                  date >= startOfWeek {
            self = .previousSevenDays
        } else {
            let components = calendar.dateComponents([.year, .month], from: date)
            self = .month(year: components.year ?? 0, month: components.month ?? 0)
        }
    }

    var id: String {
        switch self {
        case .today: "today"
        case .yesterday: "yesterday"
        case .previousSevenDays: "previous-7-days"
        case let .month(year, month): "month-\(year)-\(month)"
        }
    }

    /// The heading: a relative name, or the month, with its year only when
    /// it isn't the current one.
    func title(now: Date, calendar: Calendar) -> String {
        switch self {
        case .today: return String(localized: "Today")
        case .yesterday: return String(localized: "Yesterday")
        case .previousSevenDays: return String(localized: "Previous 7 Days")
        case let .month(year, month):
            var format = Date.FormatStyle(calendar: calendar).month(.wide)
            if calendar.component(.year, from: now) != year { format = format.year() }
            let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? now
            return date.formatted(format)
        }
    }

    /// Splits dates sorted in either direction into consecutive runs that
    /// share a section, as index ranges into `dates`.
    static func runs(of dates: [Date], now: Date, calendar: Calendar) -> [(section: Self, range: Range<Int>)] {
        var runs: [(section: Self, range: Range<Int>)] = []
        for (index, date) in dates.enumerated() {
            let section = Self(date: date, now: now, calendar: calendar)
            if let last = runs.last, last.section == section {
                runs[runs.count - 1].range = last.range.lowerBound..<(index + 1)
            } else {
                runs.append((section, index..<(index + 1)))
            }
        }
        return runs
    }
}
