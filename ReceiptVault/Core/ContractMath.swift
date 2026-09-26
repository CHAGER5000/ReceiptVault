import Foundation

/// The facts that decide a contract's dates. `termEnd` is the last day of the
/// first term, as entered; every later term is counted from it.
struct ContractFacts: Equatable {
    var termEnd: DayDate
    var autoRenews: Bool
    var renewalMonths: Int
    var notice: NoticePeriod
    var cancelled: Bool
}

/// Where a contract stands on a given day.
struct ContractStatus: Equatable {
    /// The last day of the current term.
    var termEnd: DayDate
    /// The last day notice can arrive ('Notice must arrive by').
    var noticeBy: DayDate
    /// The last day to post it, allowing for the postal buffer.
    var sendBy: DayDate
    /// Terms rolled past because their notice deadline had gone. Above 0,
    /// the app shows 'Earlier notice dates have passed'.
    var skippedTerms: Int
    /// Cancelled, not renewing or without a renewal length: the contract
    /// simply ends on `termEnd`.
    var endsWithoutRenewal: Bool
}

/// Contract date maths with no month-end drift. Dates are counted from the
/// day after a term ends and then one day is taken off, so 31 Dec with
/// 3 months' notice gives 30 Sep and 30 Jun gives 31 Mar. Never use
/// 'term end − notice', which gives 30 Mar for a 30 Jun end.
enum ContractMath {
    /// The most terms `status` rolls forward.
    static let maxTerms = 600

    /// Counts from user data are capped here, so the day arithmetic cannot
    /// overflow on a wild value.
    private static let countLimit = 1_000_000

    private static func bounded(_ n: Int) -> Int {
        min(max(n, -ContractMath.countLimit), ContractMath.countLimit)
    }

    /// The last day notice can arrive: (termEnd + 1 day) − notice − 1 day.
    /// Weeks are 7 days. No notice (0) gives `termEnd` itself.
    static func noticeDeadline(termEnd: DayDate, notice: NoticePeriod) -> DayDate {
        guard notice.value > 0 else { return termEnd }
        let n = ContractMath.bounded(notice.value)
        let next = RVCalendar.adding(days: 1, to: termEnd)
        let periodStart: DayDate
        switch notice.unit {
        case .days: periodStart = RVCalendar.adding(days: -n, to: next)
        case .weeks: periodStart = RVCalendar.adding(days: -7 * n, to: next)
        case .months: periodStart = RVCalendar.adding(months: -n, to: next)
        }
        return RVCalendar.adding(days: -1, to: periodStart)
    }

    /// The last day of term `index` (0 = the first term), always counted
    /// from the first: (first + 1 day) + index × renewalMonths − 1 day. A
    /// monthly contract from 31 Jan ends 28 Feb, 31 Mar, 30 Apr.
    static func termEnd(first: DayDate, renewalMonths: Int, index: Int) -> DayDate {
        let months = ContractMath.bounded(renewalMonths) * ContractMath.bounded(index)
        let next = RVCalendar.adding(days: 1, to: first)
        return RVCalendar.adding(days: -1, to: RVCalendar.adding(months: months, to: next))
    }

    /// The last day to post notice: `postalBufferDays` working days
    /// (Mon–Fri, no holiday tables) before it must arrive.
    static func sendBy(noticeBy: DayDate, postalBufferDays: Int) -> DayDate {
        let buffer = min(max(postalBufferDays, 0), ContractMath.countLimit)
        return RVCalendar.subtractingWorkingDays(buffer, from: noticeBy)
    }

    /// Where the contract stands on `today`. A cancelled or non-renewing
    /// contract, or one with no renewal length, stays on its first term and
    /// ends. Otherwise terms roll forward while their notice deadline is
    /// before today, so a deadline of today is still actionable. At most
    /// `maxTerms` terms are rolled.
    static func status(_ c: ContractFacts, today: DayDate, postalBufferDays: Int) -> ContractStatus {
        let ends = c.cancelled || !c.autoRenews || c.renewalMonths <= 0
        var index = 0
        var end = c.termEnd
        var arriveBy = ContractMath.noticeDeadline(termEnd: end, notice: c.notice)
        if !ends {
            while arriveBy < today && index < ContractMath.maxTerms {
                index += 1
                end = ContractMath.termEnd(first: c.termEnd, renewalMonths: c.renewalMonths, index: index)
                arriveBy = ContractMath.noticeDeadline(termEnd: end, notice: c.notice)
            }
        }
        return ContractStatus(
            termEnd: end,
            noticeBy: arriveBy,
            sendBy: ContractMath.sendBy(noticeBy: arriveBy, postalBufferDays: postalBufferDays),
            skippedTerms: index,
            endsWithoutRenewal: ends
        )
    }

    /// The first day on or after `today` with this month and day, for
    /// contracts that always end on a fixed date (Swiss basic health
    /// insurance: 12, 31). A day past the month's end is clamped, so 29 Feb
    /// gives 28 Feb outside leap years.
    static func nextFixedEnd(month: Int, day: Int, after today: DayDate) -> DayDate {
        let m = min(max(month, 1), 12)
        let d = min(max(day, 1), 31)
        func fixed(year: Int) -> DayDate {
            // adding(months: 0) clamps the day to the month's length.
            RVCalendar.adding(months: 0, to: DayDate(year: year, month: m, day: d))
        }
        let thisYear = fixed(year: today.year)
        return thisYear < today ? fixed(year: today.year + 1) : thisYear
    }
}
