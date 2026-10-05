import Foundation

// Exercises how the Library groups time-sorted captures under date headings.
@main
struct LibraryDateSectionChecks {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ month: Int, _ day: Int, _ hour: Int = 12, year: Int = 2026) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        let now = date(10, 5, 9)
        func section(_ value: Date) -> CaptureLibraryDateSection {
            CaptureLibraryDateSection(date: value, now: now, calendar: calendar)
        }

        precondition(section(date(10, 5, 0)) == .today, "Midnight starts today")
        precondition(section(date(10, 5, 23)) == .today, "A future time today is today")
        precondition(section(date(10, 7)) == .today, "A future date counts as today")
        precondition(section(date(10, 4, 23)) == .yesterday)
        precondition(section(date(10, 4, 0)) == .yesterday)
        precondition(section(date(10, 3, 23)) == .previousSevenDays)
        precondition(section(date(9, 28, 0)) == .previousSevenDays, "Seven days before today's start")
        precondition(section(date(9, 27, 23)) == .month(year: 2026, month: 9))
        precondition(section(date(12, 31, year: 2025)) == .month(year: 2025, month: 12))

        // Newest first: each section is one consecutive run.
        let newest = [date(10, 5, 8), date(10, 5, 1), date(10, 4), date(10, 1), date(9, 20), date(9, 2), date(8, 30)]
        let runs = CaptureLibraryDateSection.runs(of: newest, now: now, calendar: calendar)
        precondition(runs.map(\.section) == [.today, .yesterday, .previousSevenDays,
                                             .month(year: 2026, month: 9), .month(year: 2026, month: 8)])
        precondition(runs.map(\.range) == [0..<2, 2..<3, 3..<4, 4..<6, 6..<7])

        // Oldest first gives the same sections in reverse.
        let oldest = CaptureLibraryDateSection.runs(of: newest.reversed(), now: now, calendar: calendar)
        precondition(oldest.map(\.section) == runs.map(\.section).reversed())
        precondition(oldest.map(\.range.count) == runs.map(\.range.count).reversed())

        precondition(CaptureLibraryDateSection.runs(of: [], now: now, calendar: calendar).isEmpty)

        // Ids stay distinct across years so collection sections never collide.
        precondition(CaptureLibraryDateSection.month(year: 2025, month: 9).id
                     != CaptureLibraryDateSection.month(year: 2026, month: 9).id)

        print("Library date section checks passed.")
    }
}
