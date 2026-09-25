import Foundation

/// A calendar day with no time and no time zone. SwiftData stores it as the
/// day's UTC midnight, converted with RVCalendar.date(_:) and RVCalendar.day(_:).
struct DayDate: Hashable, Codable, Comparable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Reads "2024-03-12" (month and day may have one digit). Nil for any
    /// other shape and for a day that does not exist.
    init?(iso: String) {
        let parts = iso.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4,
              (1...2).contains(parts[1].count), (1...2).contains(parts[2].count),
              parts.allSatisfy({ part in part.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        let value = DayDate(year: y, month: m, day: d)
        guard RVCalendar.isValid(value) else { return nil }
        self = value
    }

    /// "2024-03-12".
    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    static func < (a: DayDate, b: DayDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// Gregorian day arithmetic in UTC. A stored Date is the day's UTC midnight
/// (LocalLedger's LedgerCalendar convention), so a day never moves when the
/// phone changes time zone. The maths is plain integer day numbers, so it
/// gives the same answer on every platform.
enum RVCalendar {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// The day's UTC midnight.
    static func date(_ d: DayDate) -> Date {
        Date(timeIntervalSince1970: TimeInterval(dayNumber(d)) * 86_400)
    }

    /// The UTC calendar day that contains `date`.
    static func day(_ date: Date) -> DayDate {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite, abs(seconds) < 1e13 else { return DayDate(year: 1970, month: 1, day: 1) }
        return fromDayNumber(Int((seconds / 86_400).rounded(.down)))
    }

    /// Today on the wall clock of `timeZone` (the user's, by default).
    static func today(now: Date = Date(), timeZone: TimeZone = .current) -> DayDate {
        day(now.addingTimeInterval(TimeInterval(timeZone.secondsFromGMT(for: now))))
    }

    static func adding(days: Int, to d: DayDate) -> DayDate {
        fromDayNumber(dayNumber(d) + days)
    }

    /// Clamps to the end of a shorter month: 2024-01-31 + 1 = 2024-02-29.
    /// Negative values count back.
    static func adding(months: Int, to d: DayDate) -> DayDate {
        let total = d.year * 12 + (d.month - 1) + months
        let year = floorDiv(total, 12)
        let month = total - year * 12 + 1
        return DayDate(year: year, month: month, day: min(max(d.day, 1), daysInMonth(year: year, month: month)))
    }

    static func adding(years: Int, to d: DayDate) -> DayDate {
        adding(months: years * 12, to: d)
    }

    /// b − a, in days.
    static func daysBetween(_ a: DayDate, _ b: DayDate) -> Int {
        dayNumber(b) - dayNumber(a)
    }

    /// A real day: month 1...12, day within the month, year 1...9999.
    static func isValid(_ d: DayDate) -> Bool {
        (1...9999).contains(d.year) && (1...12).contains(d.month)
            && d.day >= 1 && d.day <= daysInMonth(year: d.year, month: d.month)
    }

    /// 1 = Sunday ... 7 = Saturday, as in Calendar.
    static func weekday(_ d: DayDate) -> Int {
        weekdayOf(number: dayNumber(d))
    }

    /// Steps back to a weekday if `d` is a Saturday or Sunday, then counts
    /// back `n` Monday–Friday days. No holiday tables.
    static func subtractingWorkingDays(_ n: Int, from d: DayDate) -> DayDate {
        var number = dayNumber(d)
        while isWeekend(number) { number -= 1 }
        var left = max(n, 0)
        number -= (left / 5) * 7 // from a weekday, five working days are one week
        left %= 5
        while left > 0 {
            number -= 1
            if !isWeekend(number) { left -= 1 }
        }
        return fromDayNumber(number)
    }

    /// The one counting convention for day periods: the last day to act is
    /// start + days (2024-03-12 with 28 days gives 2024-04-09).
    static func periodEnd(from start: DayDate, days: Int) -> DayDate {
        adding(days: days, to: start)
    }

    /// Month and year periods end the day before the anniversary, which errs
    /// early (2024-03-12 with 6 months gives 2024-09-11). Callers skip 0.
    static func periodEnd(from start: DayDate, months: Int) -> DayDate {
        adding(days: -1, to: adding(months: months, to: start))
    }

    // MARK: Day numbers (days since 1970-01-01, proleptic Gregorian)

    private static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Division rounding down, for a positive divisor.
    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }

    /// Howard Hinnant's days_from_civil. Months and days out of range roll
    /// over, like a lenient Calendar (2024-02-30 is 2024-03-01).
    private static func dayNumber(_ d: DayDate) -> Int {
        let carry = floorDiv(d.month - 1, 12)
        let year = d.year + carry
        let month = d.month - carry * 12                  // 1...12
        let y = month <= 2 ? year - 1 : year
        let era = floorDiv(y, 400)
        let yoe = y - era * 400                           // 0...399
        let mp = month > 2 ? month - 3 : month + 9        // March = 0
        let doy = (153 * mp + 2) / 5 + d.day - 1          // 0...365 for a real day
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Howard Hinnant's civil_from_days.
    private static func fromDayNumber(_ n: Int) -> DayDate {
        let z = n + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097                                          // 0...146096
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365   // 0...399
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)                    // 0...365
        let mp = (5 * doy + 2) / 153                                         // 0...11, March = 0
        let dd = doy - (153 * mp + 2) / 5 + 1
        let mm = mp < 10 ? mp + 3 : mp - 9
        return DayDate(year: yoe + era * 400 + (mm <= 2 ? 1 : 0), month: mm, day: dd)
    }

    /// 1970-01-01 (day 0) was a Thursday, weekday 5.
    private static func weekdayOf(number n: Int) -> Int {
        let shifted = n + 4
        return shifted - floorDiv(shifted, 7) * 7 + 1
    }

    private static func isWeekend(_ number: Int) -> Bool {
        let w = weekdayOf(number: number)
        return w == 1 || w == 7
    }
}

/// A date found in a line of text. `location` and `length` are UTF-16
/// offsets (NSString), ready for NSRange.
struct FoundDate: Equatable {
    var date: DayDate
    var location: Int
    var length: Int
    /// The text also contains a time of day ("14:32", or the French "14h32").
    var hasTime: Bool
}

/// Finds dates anywhere in a line, in English, German, French and Italian.
/// Each pattern checks the whole shape before a number is trusted, because
/// Apple's DateFormatter ignores separators.
enum DateFinder {
    /// Month names and abbreviations, lowercased: LocalLedger's table plus
    /// "marz" and Italian. Built from arrays, so a repeated name cannot crash.
    static let months: [String: Int] = {
        let names: [[String]] = [
            ["jan", "january", "januar", "janvier", "janv", "jän", "jänner", "gen", "gennaio"],
            ["feb", "february", "februar", "février", "fevrier", "févr", "fevr", "febbraio"],
            ["mar", "march", "märz", "maerz", "mrz", "mär", "mars", "marz", "marzo"],
            ["apr", "april", "avril", "avr", "aprile"],
            ["may", "mai", "mag", "maggio"],
            ["jun", "june", "juni", "juin", "giu", "giugno"],
            ["jul", "july", "juli", "juillet", "juil", "lug", "luglio"],
            ["aug", "august", "août", "aout", "ago", "agosto"],
            ["sep", "sept", "september", "septembre", "set", "settembre"],
            ["oct", "october", "okt", "oktober", "octobre", "ott", "ottobre"],
            ["nov", "november", "novembre"],
            ["dec", "december", "dez", "dezember", "décembre", "decembre", "déc", "dic", "dicembre"],
        ]
        var m: [String: Int] = [:]
        for (i, list) in names.enumerated() { for n in list { m[n] = i + 1 } }
        return m
    }()

    /// The same names without accents, for text that lost them ("Janner").
    private static let foldedMonths: [String: Int] = {
        var m: [String: Int] = [:]
        for (name, number) in DateFinder.months { m[DateFinder.fold(name)] = number }
        return m
    }()

    private static let years = 1990...2100

    /// Patterns are compiled without .caseInsensitive (the few letters that
    /// need it are spelt out), so case folding never reaches a lookbehind.
    /// A pattern that fails to compile finds nothing rather than crashing.
    private static func compile(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    /// "2024-03-12" or "2024/03/12". A "-" just before is allowed only after
    /// a digit, so the end of a range ("…2025-2025-12-31") is still found.
    private static let isoDate = compile(#"(?<![\d.,/])(?<![^\d]-)(\d{4})([-/])(\d{1,2})\2(\d{1,2})(?!\d)"#)
    /// "12/03/2024", "12.03.24", "12-03-2024": the same separator twice. Not
    /// inside a longer dotted number ("1.12.03.24").
    private static let numericDate = compile(#"(?<![\d.,/])(?<![^\d]-)(\d{1,2})([./-])(\d{1,2})\2(\d{4}|\d{2})(?!\d|[.,]\d)"#)
    /// "12 Mar 2024", "12. März 2024", "1er mars 2024", "12th March 2024",
    /// "12-Mar-2024", "12-MAR-24" (two-digit years only with - or /).
    private static let dayFirstNamed = compile(#"(?<![\p{L}\d])(\d{1,2})(?:[eE][rR]|[sS][tT]|[nN][dD]|[rR][dD]|[tT][hH]|°|º)?(?:\.?\s?|[-/])([\p{L}\p{M}]{3,12})(?:\.?,?\s(\d{4})|\.?[-/](\d{4}|\d{2}))(?!\d)"#)
    /// "March 12, 2024", "Mar. 12th 2024".
    private static let monthFirstNamed = compile(#"(?<![\p{L}\p{M}])([\p{L}\p{M}]{3,12})\.?\s(\d{1,2})(?:[sS][tT]|[nN][dD]|[rR][dD]|[tT][hH])?,?\s(\d{4})(?!\d)"#)
    /// "14:32", "9:05", "14h32".
    private static let timeOfDay = compile(#"(?<![\d:])(?:[01]?\d|2[0-3])[:hH][0-5]\d(?!\d)"#)

    /// The month for a name or abbreviation in any case, ignoring a trailing
    /// "." and, when there is no exact match, accents.
    static func month(named raw: String) -> Int? {
        var name = raw.precomposedStringWithCanonicalMapping.lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        if let m = DateFinder.months[name] { return m }
        return DateFinder.foldedMonths[DateFinder.fold(name)]
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// Every date in `text`, sorted by location. Numeric dates are day-first
    /// and swap only when that reading is impossible ("04/13/2024" is 13 April);
    /// with `dayFirst` false they read month-first when both readings work.
    /// Two-digit years below 70 are 20yy. Days that do not exist, years outside
    /// 1990...2100 and overlapping matches are dropped.
    static func dates(in text: String, dayFirst: Bool = true) -> [FoundDate] {
        guard text.contains(where: { $0.isNumber }) else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [FoundDate] = []

        func number(_ m: NSTextCheckingResult, _ group: Int) -> Int? {
            let r = m.range(at: group)
            guard r.location != NSNotFound else { return nil }
            return Int(ns.substring(with: r))
        }
        func fullYear(_ m: NSTextCheckingResult, _ group: Int) -> Int? {
            guard let y = number(m, group) else { return nil }
            guard m.range(at: group).length == 2 else { return y }
            return y < 70 ? 2000 + y : 1900 + y
        }
        func keep(_ m: NSTextCheckingResult, year: Int, month: Int, day: Int) {
            let d = DayDate(year: year, month: month, day: day)
            guard DateFinder.years.contains(year), RVCalendar.isValid(d) else { return }
            found.append(FoundDate(date: d, location: m.range.location, length: m.range.length, hasTime: false))
        }

        if let regex = DateFinder.isoDate {
            for m in regex.matches(in: text, range: full) {
                guard let y = number(m, 1), let mo = number(m, 3), let d = number(m, 4) else { continue }
                keep(m, year: y, month: mo, day: d)
            }
        }
        if let regex = DateFinder.numericDate {
            for m in regex.matches(in: text, range: full) {
                guard let first = number(m, 1), let second = number(m, 3), let y = fullYear(m, 4) else { continue }
                var d = first
                var mo = second
                if !dayFirst && first <= 12 && second <= 12 {
                    swap(&d, &mo) // month-first when both readings are possible
                } else if mo > 12 && d <= 12 {
                    swap(&d, &mo) // the day-first reading is impossible
                }
                keep(m, year: y, month: mo, day: d)
            }
        }
        if let regex = DateFinder.dayFirstNamed {
            for m in regex.matches(in: text, range: full) {
                guard let d = number(m, 1),
                      let mo = DateFinder.month(named: ns.substring(with: m.range(at: 2))),
                      let y = number(m, 3) ?? fullYear(m, 4) else { continue }
                keep(m, year: y, month: mo, day: d)
            }
        }
        if let regex = DateFinder.monthFirstNamed {
            for m in regex.matches(in: text, range: full) {
                guard let mo = DateFinder.month(named: ns.substring(with: m.range(at: 1))),
                      let d = number(m, 2), let y = number(m, 3) else { continue }
                keep(m, year: y, month: mo, day: d)
            }
        }

        found.sort { a, b in a.location != b.location ? a.location < b.location : a.length > b.length }
        var result: [FoundDate] = []
        var end = 0
        for f in found {
            guard f.location >= end else { continue }
            result.append(f)
            end = f.location + f.length
        }
        if !result.isEmpty, let regex = DateFinder.timeOfDay, regex.firstMatch(in: text, range: full) != nil {
            for i in result.indices { result[i].hasTime = true }
        }
        return result
    }
}
