import Foundation
import XCTest
@testable import ReceiptCore

/// ContractMath, DeadlineRules and ReminderPlanner. Every 'today' and every
/// time of day is fixed (never Date()), so each expected date is exact.
final class RulesTests: XCTestCase {
    /// The 'today' used when a test does not name one.
    private static let fixedToday = DayDate(year: 2026, month: 9, day: 25)

    private func day(_ y: Int, _ m: Int, _ d: Int) -> DayDate {
        DayDate(year: y, month: m, day: d)
    }

    /// A receipt with nothing printed or entered: new, no fault, no total.
    private func facts(_ j: Jurisdiction, bought: DayDate, delivered: DayDate? = nil,
                       channel: PurchaseChannel = .store, category: ProductCategory = .electronics) -> PurchaseFacts {
        PurchaseFacts(kind: .receipt, purchaseDate: bought, deliveryDate: delivered, jurisdiction: j,
                      channel: channel, category: category, isUsed: false, hasIssue: false, totalMinor: nil,
                      warrantyMonths: nil, warrantyIsPrinted: false, returnDays: nil, returnDaysIsPrinted: false,
                      contract: nil)
    }

    /// The planner's dates, with the built-in rules unless others are given.
    private func deadlines(_ f: PurchaseFacts, rules: RuleBook = RuleBook.defaults,
                           today: DayDate = RulesTests.fixedToday) -> [PlannedDeadline] {
        DeadlinePlanner.plan(f, rules: rules, today: today)
    }

    private func find(_ kind: DeadlineKind, in list: [PlannedDeadline]) -> PlannedDeadline? {
        list.first(where: { $0.kind == kind })
    }

    /// `first` is the last day of the first term.
    private func contract(_ first: DayDate, months: Int, notice: NoticePeriod,
                          autoRenews: Bool = true, cancelled: Bool = false) -> ContractFacts {
        ContractFacts(termEnd: first, autoRenews: autoRenews, renewalMonths: months, notice: notice, cancelled: cancelled)
    }

    /// A contract item carrying `c`.
    private func contractItem(_ c: ContractFacts, total: Int64? = nil) -> PurchaseFacts {
        var f = facts(.switzerland, bought: c.termEnd, category: .service)
        f.kind = .contract
        f.contract = c
        f.totalMinor = total
        return f
    }

    private func input(_ id: String, item: String, kind: DeadlineKind = .returnWindow, date: DayDate, offsets: [Int],
                       title: String = "Sony WH-1000XM5", merchant: String = "Currys", label: String = "") -> ReminderInput {
        ReminderInput(deadlineID: id, itemID: item, kind: kind, label: label, date: date, offsets: offsets,
                      itemTitle: title, merchant: merchant)
    }

    /// ReminderPlanner.plan at 08:00, with reminders at 09:00 unless given.
    private func reminders(_ inputs: [ReminderInput], today: DayDate, now: Int = 8 * 60, hour: Int = 9, minute: Int = 0,
                           privateText: Bool = false, limit: Int = ReminderPlanner.limit) -> [PlannedReminder] {
        ReminderPlanner.plan(inputs, today: today, nowMinutes: now, hour: hour, minute: minute,
                             privateText: privateText, limit: limit)
    }

    // MARK: - ContractMath

    /// Counted from the day after the term ends, so month ends never drift.
    func testNoticeDeadlineMonthEnds() {
        let threeMonths = NoticePeriod(value: 3, unit: .months)
        XCTAssertEqual(ContractMath.noticeDeadline(termEnd: day(2025, 12, 31), notice: threeMonths), day(2025, 9, 30))
        XCTAssertEqual(ContractMath.noticeDeadline(termEnd: day(2025, 6, 30), notice: threeMonths), day(2025, 3, 31))
        XCTAssertEqual(ContractMath.noticeDeadline(termEnd: day(2025, 11, 30), notice: threeMonths), day(2025, 8, 31))
        XCTAssertEqual(ContractMath.noticeDeadline(termEnd: day(2025, 2, 28), notice: NoticePeriod(value: 1, unit: .months)),
                       day(2025, 1, 31))
        XCTAssertEqual(ContractMath.noticeDeadline(termEnd: day(2025, 12, 31), notice: NoticePeriod(value: 30, unit: .days)),
                       day(2025, 12, 1))
        XCTAssertEqual(ContractMath.noticeDeadline(termEnd: day(2025, 12, 31), notice: NoticePeriod(value: 6, unit: .weeks)),
                       day(2025, 11, 19))
        // No notice: the term end itself.
        XCTAssertEqual(ContractMath.noticeDeadline(termEnd: day(2025, 12, 31), notice: NoticePeriod(value: 0, unit: .months)),
                       day(2025, 12, 31))
        // Never 'term end − notice', which would give 30 March.
        XCTAssertNotEqual(ContractMath.noticeDeadline(termEnd: day(2025, 6, 30), notice: threeMonths), day(2025, 3, 30))
    }

    func testRollForwardWithoutDrift() {
        let annual = contract(day(2023, 12, 31), months: 12, notice: NoticePeriod(value: 3, unit: .months))
        let status = ContractMath.status(annual, today: day(2025, 10, 15), postalBufferDays: 5)
        XCTAssertEqual(status.termEnd, day(2026, 12, 31))
        XCTAssertEqual(status.noticeBy, day(2026, 9, 30))
        XCTAssertEqual(status.sendBy, day(2026, 9, 23))
        XCTAssertEqual(status.skippedTerms, 3)
        XCTAssertFalse(status.endsWithoutRenewal)

        // Every term is counted from the first, so 31 January never drifts to the 28th.
        let first = day(2025, 1, 31)
        XCTAssertEqual((0...3).map { ContractMath.termEnd(first: first, renewalMonths: 1, index: $0) },
                       [day(2025, 1, 31), day(2025, 2, 28), day(2025, 3, 31), day(2025, 4, 30)])
        let leap = day(2024, 2, 29)
        XCTAssertEqual((0...4).map { ContractMath.termEnd(first: leap, renewalMonths: 12, index: $0) },
                       [day(2024, 2, 29), day(2025, 2, 28), day(2026, 2, 28), day(2027, 2, 28), day(2028, 2, 29)])

        // A monthly contract from 2000 still rolls forward to the current term.
        let monthly = contract(day(2000, 1, 31), months: 1, notice: NoticePeriod(value: 1, unit: .months))
        let rolled = ContractMath.status(monthly, today: day(2026, 9, 25), postalBufferDays: 5)
        XCTAssertEqual(rolled.termEnd, day(2026, 10, 31))
        XCTAssertEqual(rolled.noticeBy, day(2026, 9, 30))
        XCTAssertEqual(rolled.skippedTerms, 321)
    }

    /// Terms roll only once the notice deadline is before today: on the day
    /// itself, notice can still arrive.
    func testDeadlineTodayIsStillActionable() {
        let annual = contract(day(2025, 12, 31), months: 12, notice: NoticePeriod(value: 3, unit: .months))
        let onTheDay = ContractMath.status(annual, today: day(2025, 9, 30), postalBufferDays: 5)
        XCTAssertEqual(onTheDay.termEnd, day(2025, 12, 31))
        XCTAssertEqual(onTheDay.noticeBy, day(2025, 9, 30))
        XCTAssertEqual(onTheDay.skippedTerms, 0)

        let dayAfter = ContractMath.status(annual, today: day(2025, 10, 1), postalBufferDays: 5)
        XCTAssertEqual(dayAfter.termEnd, day(2026, 12, 31))
        XCTAssertEqual(dayAfter.noticeBy, day(2026, 9, 30))
        XCTAssertEqual(dayAfter.skippedTerms, 1)

        // The planner keeps the date, and a reminder still fires that morning.
        let planned = deadlines(contractItem(annual), today: day(2025, 9, 30))
        XCTAssertEqual(find(.noticeDeadline, in: planned)?.date, day(2025, 9, 30))
        let morning = reminders([input("n", item: "c1", kind: .noticeDeadline, date: day(2025, 9, 30), offsets: [30, 14, 3])],
                                today: day(2025, 9, 30))
        XCTAssertEqual(morning.map { $0.fireDay }, [day(2025, 9, 30)])
        XCTAssertEqual(morning.first?.title, "Notice must arrive today")
    }

    func testSendBy() {
        XCTAssertEqual(ContractMath.sendBy(noticeBy: day(2026, 9, 30), postalBufferDays: 5), day(2026, 9, 23))
        XCTAssertEqual(ContractMath.sendBy(noticeBy: day(2026, 9, 30), postalBufferDays: 0), day(2026, 9, 30))
        XCTAssertEqual(ContractMath.sendBy(noticeBy: day(2026, 11, 30), postalBufferDays: 1), day(2026, 11, 27)) // Mon → Fri
        XCTAssertEqual(ContractMath.sendBy(noticeBy: day(2026, 10, 3), postalBufferDays: 0), day(2026, 10, 2))   // Sat → Fri
        XCTAssertEqual(ContractMath.sendBy(noticeBy: day(2026, 10, 4), postalBufferDays: 5), day(2026, 9, 25))   // Sun
        XCTAssertEqual(ContractMath.sendBy(noticeBy: day(2026, 9, 30), postalBufferDays: -3), day(2026, 9, 30))
    }

    /// Swiss basic health insurance: 31 December with 1 month's notice.
    func testKVG() {
        let end = ContractMath.nextFixedEnd(month: 12, day: 31, after: day(2026, 9, 25))
        XCTAssertEqual(end, day(2026, 12, 31))
        let oneMonth = NoticePeriod(value: 1, unit: .months)
        let noticeBy = ContractMath.noticeDeadline(termEnd: end, notice: oneMonth)
        XCTAssertEqual(noticeBy, day(2026, 11, 30))
        XCTAssertEqual(ContractMath.sendBy(noticeBy: noticeBy, postalBufferDays: 5), day(2026, 11, 23))

        // The preset carries the fixed end and the notice.
        let preset = RuleBook.defaults.preset(id: "chHealthKVG")
        XCTAssertEqual(preset?.fixedEndMonth, 12)
        XCTAssertEqual(preset?.fixedEndDay, 31)
        XCTAssertEqual(preset?.renewalMonths, 12)
        XCTAssertEqual(preset?.notice, oneMonth)
        XCTAssertEqual(preset?.isAssumption, true)

        let kvg = contract(end, months: 12, notice: oneMonth)
        XCTAssertEqual(ContractMath.status(kvg, today: day(2026, 9, 25), postalBufferDays: 5),
                       ContractStatus(termEnd: day(2026, 12, 31), noticeBy: day(2026, 11, 30), sendBy: day(2026, 11, 23),
                                      skippedTerms: 0, endsWithoutRenewal: false))

        // On or after today: 31 December itself, then the next year's.
        XCTAssertEqual(ContractMath.nextFixedEnd(month: 12, day: 31, after: day(2026, 12, 31)), day(2026, 12, 31))
        XCTAssertEqual(ContractMath.nextFixedEnd(month: 12, day: 31, after: day(2027, 1, 1)), day(2027, 12, 31))
        XCTAssertEqual(ContractMath.nextFixedEnd(month: 6, day: 30, after: day(2026, 9, 25)), day(2027, 6, 30))
        // 29 February outside a leap year is the 28th.
        XCTAssertEqual(ContractMath.nextFixedEnd(month: 2, day: 29, after: day(2025, 3, 1)), day(2026, 2, 28))
        XCTAssertEqual(ContractMath.nextFixedEnd(month: 2, day: 29, after: day(2027, 6, 1)), day(2028, 2, 29))
    }

    func testCancelledOrNonRenewingEnds() {
        let today = day(2026, 9, 25)
        let three = NoticePeriod(value: 3, unit: .months)
        let ended = ContractStatus(termEnd: day(2026, 6, 30), noticeBy: day(2026, 3, 31), sendBy: day(2026, 3, 24),
                                   skippedTerms: 0, endsWithoutRenewal: true)
        let variants = [
            contract(day(2026, 6, 30), months: 12, notice: three, cancelled: true),
            contract(day(2026, 6, 30), months: 12, notice: three, autoRenews: false),
            contract(day(2026, 6, 30), months: 0, notice: three),
        ]
        for c in variants {
            XCTAssertEqual(ContractMath.status(c, today: today, postalBufferDays: 5), ended)
            // Only 'Contract ends', and it reminds.
            let planned = deadlines(contractItem(c), today: today)
            XCTAssertEqual(planned.map { $0.kind }, [DeadlineKind.termEnd])
            XCTAssertEqual(planned.first?.date, day(2026, 6, 30))
            XCTAssertEqual(planned.first?.remindByDefault, true)
        }

        // The same contract, renewing, rolls on a year.
        let renewing = ContractMath.status(contract(day(2026, 6, 30), months: 12, notice: three),
                                           today: today, postalBufferDays: 5)
        XCTAssertEqual(renewing.termEnd, day(2027, 6, 30))
        XCTAssertEqual(renewing.noticeBy, day(2027, 3, 31))
        XCTAssertEqual(renewing.skippedTerms, 1)
        XCTAssertFalse(renewing.endsWithoutRenewal)
    }

    // MARK: - DeadlineRules

    func testEnglandElectronicsInStore() {
        let planned = deadlines(facts(.englandWales, bought: day(2024, 3, 12)))
        XCTAssertEqual(planned.map { $0.kind },
                       [DeadlineKind.returnWindow, .rightToReject, .faultPresumption, .manufacturerWarranty, .claimLimit])
        XCTAssertEqual(planned.map { $0.date },
                       [day(2024, 4, 9), day(2024, 4, 11), day(2024, 9, 11), day(2025, 3, 11), day(2030, 3, 11)])
        XCTAssertEqual(find(.returnWindow, in: planned)?.certainty, Certainty.assumption)
        XCTAssertEqual(find(.returnWindow, in: planned)?.basis, "Typical shop policy, not a legal right")
        XCTAssertEqual(find(.rightToReject, in: planned)?.certainty, Certainty.law)
        XCTAssertEqual(find(.rightToReject, in: planned)?.basis, "Consumer Rights Act 2015, s.22")
        XCTAssertEqual(find(.rightToReject, in: planned)?.remindByDefault, false)
        XCTAssertEqual(find(.faultPresumption, in: planned)?.certainty, Certainty.law)
        XCTAssertEqual(find(.manufacturerWarranty, in: planned)?.certainty, Certainty.assumption)
        XCTAssertEqual(find(.claimLimit, in: planned)?.certainty, Certainty.law)
        XCTAssertNil(find(.cancellation, in: planned))
        XCTAssertNil(find(.legalGuarantee, in: planned))
        XCTAssertEqual(planned.filter { $0.remindByDefault }.map { $0.kind },
                       [DeadlineKind.returnWindow, .manufacturerWarranty])
        XCTAssertEqual(find(.returnWindow, in: planned)?.offsets ?? [], [3, 1])
        XCTAssertEqual(find(.manufacturerWarranty, in: planned)?.offsets ?? [], [30, 7])
        XCTAssertEqual(find(.claimLimit, in: planned)?.offsets ?? [], [90])
    }

    func testUKOnlineFromDelivery() {
        let f = facts(.englandWales, bought: day(2025, 3, 5), delivered: day(2025, 3, 10), channel: .online)
        let planned = deadlines(f)
        XCTAssertEqual(find(.cancellation, in: planned)?.date, day(2025, 3, 24))
        XCTAssertEqual(find(.cancellation, in: planned)?.basis, "Consumer Contracts Regulations 2013")
        XCTAssertEqual(find(.cancellation, in: planned)?.certainty, Certainty.law)
        XCTAssertEqual(find(.cancellation, in: planned)?.remindByDefault, true)
        XCTAssertEqual(find(.rightToReject, in: planned)?.date, day(2025, 4, 9))
        XCTAssertEqual(find(.faultPresumption, in: planned)?.date, day(2025, 9, 9))
        XCTAssertEqual(find(.claimLimit, in: planned)?.date, day(2031, 3, 9))
        // The manufacturer warranty runs from purchase, not delivery.
        XCTAssertEqual(find(.manufacturerWarranty, in: planned)?.date, day(2026, 3, 4))

        // Online, a shop return window appears only when printed or entered,
        // and then runs from delivery.
        XCTAssertNil(find(.returnWindow, in: planned))
        var printed = f
        printed.returnDays = 30
        printed.returnDaysIsPrinted = true
        let withReturns = deadlines(printed)
        XCTAssertEqual(find(.returnWindow, in: withReturns)?.date, day(2025, 4, 9))
        XCTAssertEqual(find(.returnWindow, in: withReturns)?.certainty, Certainty.printed)

        // Doorstep and phone sales have the same 14 days.
        let doorstep = deadlines(facts(.englandWales, bought: day(2025, 3, 10), channel: .doorstep))
        XCTAssertEqual(find(.cancellation, in: doorstep)?.date, day(2025, 3, 24))
    }

    func testScotlandFiveYears() {
        let planned = deadlines(facts(.scotland, bought: day(2025, 3, 5), delivered: day(2025, 3, 10), channel: .online))
        let claim = find(.claimLimit, in: planned)
        XCTAssertEqual(claim?.date, day(2030, 3, 9))
        XCTAssertEqual(claim?.certainty, Certainty.assumption)
        XCTAssertEqual(claim?.basis, "Prescription and Limitation (Scotland) Act 1973; start date simplified")

        // Everything else is the same as in England.
        let england = deadlines(facts(.englandWales, bought: day(2025, 3, 5), delivered: day(2025, 3, 10), channel: .online))
        XCTAssertEqual(planned.filter { $0.kind != .claimLimit }, england.filter { $0.kind != .claimLimit })
    }

    func testSwitzerlandStore() {
        let planned = deadlines(facts(.switzerland, bought: day(2024, 3, 12)))
        XCTAssertEqual(planned.map { $0.kind }, [DeadlineKind.returnWindow, .legalGuarantee])
        XCTAssertEqual(find(.returnWindow, in: planned)?.date, day(2024, 3, 26))
        XCTAssertEqual(find(.returnWindow, in: planned)?.certainty, Certainty.assumption)
        XCTAssertEqual(find(.legalGuarantee, in: planned)?.date, day(2026, 3, 11))
        XCTAssertEqual(find(.legalGuarantee, in: planned)?.certainty, Certainty.law)
        XCTAssertEqual(find(.legalGuarantee, in: planned)?.remindByDefault, true)
        XCTAssertEqual(find(.legalGuarantee, in: planned)?.offsets ?? [], [30])
        XCTAssertNil(find(.faultPresumption, in: planned))
        XCTAssertNil(find(.manufacturerWarranty, in: planned))
        XCTAssertNil(find(.claimLimit, in: planned))

        let notes = LegalNotes.notes(for: .switzerland, channel: .store, kind: .receipt, hasIssue: false, isUsed: false)
        let text = notes.map { $0.text + " " + $0.basis }.joined(separator: "\n")
        XCTAssertTrue(text.contains("OR Art. 201"), text)
        XCTAssertTrue(text.contains("OR Art. 199"), text)
    }

    func testSwissUsedGoods12MonthsAssumption() {
        var f = facts(.switzerland, bought: day(2024, 3, 12))
        f.isUsed = true
        let legal = find(.legalGuarantee, in: deadlines(f))
        XCTAssertEqual(legal?.date, day(2025, 3, 11))
        XCTAssertEqual(legal?.certainty, Certainty.assumption)
        XCTAssertEqual(legal?.remindByDefault, true)

        // The UK has no used-goods period, so used goods keep the usual dates.
        var uk = facts(.englandWales, bought: day(2024, 3, 12))
        uk.isUsed = true
        XCTAssertEqual(deadlines(uk), deadlines(facts(.englandWales, bought: day(2024, 3, 12))))
    }

    func testEUOnline() {
        let planned = deadlines(facts(.eu, bought: day(2025, 3, 1), delivered: day(2025, 3, 10), channel: .online))
        XCTAssertEqual(planned.map { $0.kind },
                       [DeadlineKind.cancellation, .manufacturerWarranty, .faultPresumption, .legalGuarantee])
        XCTAssertEqual(find(.cancellation, in: planned)?.date, day(2025, 3, 24))
        XCTAssertEqual(find(.legalGuarantee, in: planned)?.date, day(2027, 3, 9))
        XCTAssertEqual(find(.legalGuarantee, in: planned)?.certainty, Certainty.law)
        XCTAssertEqual(find(.faultPresumption, in: planned)?.date, day(2026, 3, 9))
        XCTAssertEqual(find(.faultPresumption, in: planned)?.certainty, Certainty.assumption)
        XCTAssertEqual(find(.manufacturerWarranty, in: planned)?.date, day(2026, 2, 28))
        XCTAssertEqual(find(.manufacturerWarranty, in: planned)?.remindByDefault, true)
        XCTAssertNil(find(.returnWindow, in: planned))
        XCTAssertNil(find(.rightToReject, in: planned))
        XCTAssertNil(find(.claimLimit, in: planned))
    }

    func testPrintedWarrantyOverrides() {
        var f = facts(.englandWales, bought: day(2024, 3, 12))
        f.warrantyMonths = 36
        f.warrantyIsPrinted = true
        let printed = find(.manufacturerWarranty, in: deadlines(f))
        XCTAssertEqual(printed?.date, day(2027, 3, 11))
        XCTAssertEqual(printed?.certainty, Certainty.printed)
        XCTAssertEqual(printed?.remindByDefault, true)

        // Entered rather than printed: 'You'.
        f.warrantyIsPrinted = false
        XCTAssertEqual(find(.manufacturerWarranty, in: deadlines(f))?.certainty, Certainty.user)
        // 0 on the item means no warranty, even for electronics.
        f.warrantyMonths = 0
        XCTAssertNil(find(.manufacturerWarranty, in: deadlines(f)))

        // Furniture has no default warranty, but a printed one counts.
        var sofa = facts(.englandWales, bought: day(2024, 3, 12), category: .furniture)
        XCTAssertNil(find(.manufacturerWarranty, in: deadlines(sofa)))
        sofa.warrantyMonths = 24
        sofa.warrantyIsPrinted = true
        XCTAssertEqual(find(.manufacturerWarranty, in: deadlines(sofa))?.date, day(2026, 3, 11))
        XCTAssertEqual(find(.manufacturerWarranty, in: deadlines(sofa))?.certainty, Certainty.printed)

        // Switzerland has no default either.
        var swiss = facts(.switzerland, bought: day(2024, 3, 12))
        swiss.warrantyMonths = 36
        swiss.warrantyIsPrinted = true
        XCTAssertEqual(find(.manufacturerWarranty, in: deadlines(swiss))?.date, day(2027, 3, 11))
        XCTAssertEqual(find(.manufacturerWarranty, in: deadlines(swiss))?.certainty, Certainty.printed)
    }

    func testManufacturerNearLegalDoesNotRemind() {
        // EU: a 2-year printed warranty ends with the 2-year legal guarantee.
        var f = facts(.eu, bought: day(2024, 3, 12))
        f.warrantyMonths = 24
        f.warrantyIsPrinted = true
        var planned = deadlines(f)
        XCTAssertEqual(find(.manufacturerWarranty, in: planned)?.date, day(2026, 3, 11))
        XCTAssertEqual(find(.legalGuarantee, in: planned)?.date, day(2026, 3, 11))
        XCTAssertEqual(find(.manufacturerWarranty, in: planned)?.remindByDefault, false)
        XCTAssertEqual(find(.legalGuarantee, in: planned)?.remindByDefault, true)

        // Seven days apart is still quiet; eight days apart reminds.
        f.deliveryDate = day(2024, 3, 19)
        planned = deadlines(f)
        XCTAssertEqual(find(.legalGuarantee, in: planned)?.date, day(2026, 3, 18))
        XCTAssertEqual(find(.manufacturerWarranty, in: planned)?.remindByDefault, false)
        f.deliveryDate = day(2024, 3, 20)
        planned = deadlines(f)
        XCTAssertEqual(find(.legalGuarantee, in: planned)?.date, day(2026, 3, 19))
        XCTAssertEqual(find(.manufacturerWarranty, in: planned)?.remindByDefault, true)

        // The EU default of 12 months is a year from the guarantee and reminds.
        let usual = deadlines(facts(.eu, bought: day(2024, 3, 12)))
        XCTAssertEqual(find(.manufacturerWarranty, in: usual)?.remindByDefault, true)
    }

    func testHasIssueTurnsOnReject() {
        var f = facts(.englandWales, bought: day(2024, 3, 12))
        XCTAssertEqual(find(.rightToReject, in: deadlines(f))?.remindByDefault, false)
        f.hasIssue = true
        let planned = deadlines(f)
        let reject = find(.rightToReject, in: planned)
        XCTAssertEqual(reject?.date, day(2024, 4, 11))
        XCTAssertEqual(reject?.remindByDefault, true)
        XCTAssertEqual(reject?.offsets ?? [], [5, 1])
        // Fault presumption and the claim limit stay on the timeline only.
        XCTAssertEqual(find(.faultPresumption, in: planned)?.remindByDefault, false)
        XCTAssertEqual(find(.claimLimit, in: planned)?.remindByDefault, false)

        // The notes add what to do about the fault.
        let withIssue = LegalNotes.notes(for: .englandWales, channel: .store, kind: .receipt, hasIssue: true, isUsed: false)
        let without = LegalNotes.notes(for: .englandWales, channel: .store, kind: .receipt, hasIssue: false, isUsed: false)
        XCTAssertGreaterThan(withIssue.count, without.count)
    }

    func testUserRuleEditsApply() {
        var book = RuleBook.defaults
        var uk = book.rules(for: .englandWales)
        uk.set(.returnDaysStore, 35)
        XCTAssertEqual(uk.value(.returnDaysStore), 35)
        book.rules[Jurisdiction.englandWales.rawValue] = uk
        let planned = deadlines(facts(.englandWales, bought: day(2024, 3, 12)), rules: book)
        let back = find(.returnWindow, in: planned)
        XCTAssertEqual(back?.date, day(2024, 4, 16))
        XCTAssertEqual(back?.certainty, Certainty.user)
        XCTAssertTrue(back?.basis.contains("35 days") ?? false, back?.basis ?? "")
        // Untouched values keep their law or assumption.
        XCTAssertEqual(find(.rightToReject, in: planned)?.certainty, Certainty.law)
        XCTAssertEqual(find(.manufacturerWarranty, in: planned)?.certainty, Certainty.assumption)
        // Scotland keeps its own defaults.
        let scotland = deadlines(facts(.scotland, bought: day(2024, 3, 12)), rules: book)
        XCTAssertEqual(find(.returnWindow, in: scotland)?.date, day(2024, 4, 9))
        XCTAssertEqual(find(.returnWindow, in: scotland)?.certainty, Certainty.assumption)

        // 0 turns a rule off.
        uk.set(.rightToRejectDays, 0)
        book.rules[Jurisdiction.englandWales.rawValue] = uk
        XCTAssertNil(find(.rightToReject, in: deadlines(facts(.englandWales, bought: day(2024, 3, 12)), rules: book)))

        // Edited lead times are cleaned: no negatives or repeats, largest first.
        book.offsets[DeadlineKind.returnWindow.rawValue] = [2, 10, -1, 10]
        let edited = find(.returnWindow, in: deadlines(facts(.englandWales, bought: day(2024, 3, 12)), rules: book))
        XCTAssertEqual(edited?.offsets ?? [], [10, 2])

        // Reminder defaults can be edited too.
        book.remindByDefault[DeadlineKind.faultPresumption.rawValue] = true
        let fault = find(.faultPresumption, in: deadlines(facts(.englandWales, bought: day(2024, 3, 12)), rules: book))
        XCTAssertEqual(fault?.remindByDefault, true)

        // A return period entered on the item beats the rule book; 0 means none.
        var f = facts(.englandWales, bought: day(2024, 3, 12))
        f.returnDays = 60
        let entered = find(.returnWindow, in: deadlines(f, rules: book))
        XCTAssertEqual(entered?.date, day(2024, 5, 11))
        XCTAssertEqual(entered?.certainty, Certainty.user)
        f.returnDays = 0
        XCTAssertNil(find(.returnWindow, in: deadlines(f, rules: book)))
    }

    func testGroceriesServiceExpenseNoGoodsDates() {
        for category in [ProductCategory.groceries, .service, .expense] {
            XCTAssertFalse(category.tracksGoodsDates)
            for j in Jurisdiction.allCases {
                for channel in PurchaseChannel.allCases {
                    let f = facts(j, bought: day(2024, 3, 12), channel: channel, category: category)
                    XCTAssertTrue(deadlines(f).isEmpty, "\(category.rawValue) \(j.rawValue) \(channel.rawValue)")
                }
            }

            // A printed return period or an entered warranty still counts.
            var printed = facts(.englandWales, bought: day(2024, 3, 12), category: category)
            printed.returnDays = 14
            printed.returnDaysIsPrinted = true
            let back = deadlines(printed)
            XCTAssertEqual(back.map { $0.kind }, [DeadlineKind.returnWindow])
            XCTAssertEqual(back.first?.date, day(2024, 3, 26))
            XCTAssertEqual(back.first?.certainty, Certainty.printed)

            var covered = facts(.eu, bought: day(2024, 3, 12), category: category)
            covered.warrantyMonths = 12
            let cover = deadlines(covered)
            XCTAssertEqual(cover.map { $0.kind }, [DeadlineKind.manufacturerWarranty])
            XCTAssertEqual(cover.first?.date, day(2025, 3, 11))
            XCTAssertEqual(cover.first?.certainty, Certainty.user)
            XCTAssertEqual(cover.first?.remindByDefault, true)
        }
    }

    func testMinReminderAmount() {
        var book = RuleBook.defaults
        book.minReminderMinor = 5000
        var cheap = facts(.englandWales, bought: day(2024, 3, 12))
        cheap.totalMinor = 1299
        let quiet = deadlines(cheap, rules: book)
        XCTAssertEqual(quiet.count, 5)
        XCTAssertTrue(quiet.allSatisfy { !$0.remindByDefault })

        // At the minimum, or with no total, reminders stay on.
        var dear = cheap
        dear.totalMinor = 5000
        XCTAssertEqual(deadlines(dear, rules: book).filter { $0.remindByDefault }.map { $0.kind },
                       [DeadlineKind.returnWindow, .manufacturerWarranty])
        var unknown = cheap
        unknown.totalMinor = nil
        XCTAssertEqual(deadlines(unknown, rules: book).filter { $0.remindByDefault }.count, 2)

        // Warranty cards and contracts are never silenced.
        var card = cheap
        card.kind = .warranty
        XCTAssertEqual(find(.manufacturerWarranty, in: deadlines(card, rules: book))?.remindByDefault, true)
        let annual = contract(day(2025, 12, 31), months: 12, notice: NoticePeriod(value: 3, unit: .months))
        let planned = deadlines(contractItem(annual, total: 1299), rules: book, today: day(2026, 9, 25))
        XCTAssertEqual(find(.noticeDeadline, in: planned)?.remindByDefault, true)

        // Off by default.
        XCTAssertEqual(RuleBook.defaults.minReminderMinor, 0)
        XCTAssertEqual(deadlines(cheap).filter { $0.remindByDefault }.count, 2)
    }

    func testContractPlan() {
        let annual = contract(day(2025, 12, 31), months: 12, notice: NoticePeriod(value: 3, unit: .months))
        let planned = deadlines(contractItem(annual), today: day(2026, 9, 25))
        XCTAssertEqual(planned.map { $0.kind }, [DeadlineKind.noticeDeadline, .termEnd])
        let notice = find(.noticeDeadline, in: planned)
        XCTAssertEqual(notice?.date, day(2026, 9, 30))
        XCTAssertEqual(notice?.offsets ?? [], [30, 14, 7, 3]) // 7: the send-by day, 23 September
        XCTAssertEqual(notice?.remindByDefault, true)
        XCTAssertEqual(notice?.certainty, Certainty.user)
        let end = find(.termEnd, in: planned)
        XCTAssertEqual(end?.date, day(2026, 12, 31))
        XCTAssertEqual(end?.remindByDefault, false)
        XCTAssertEqual(end?.offsets ?? [], [30, 7])

        // A longer postal buffer moves the send-by reminder; repeats are dropped.
        var book = RuleBook.defaults
        book.postalBufferDays = 10
        let slower = find(.noticeDeadline, in: deadlines(contractItem(annual), rules: book, today: day(2026, 9, 25)))
        XCTAssertEqual(slower?.offsets ?? [], [30, 14, 3])

        // Once the deadline has passed, the next term's dates come back.
        let later = deadlines(contractItem(annual), today: day(2026, 10, 1))
        XCTAssertEqual(find(.noticeDeadline, in: later)?.date, day(2027, 9, 30))
        XCTAssertEqual(find(.termEnd, in: later)?.date, day(2027, 12, 31))

        // A contract with no term entered has no dates yet.
        var bare = facts(.switzerland, bought: day(2025, 1, 1))
        bare.kind = .contract
        XCTAssertTrue(deadlines(bare).isEmpty)
    }

    /// UK annual insurance renews with no notice: one 'renews on' reminder.
    func testZeroNoticeGivesRenewsOnReminder() {
        guard let preset = RuleBook.defaults.preset(id: "ukAnnualInsurance") else {
            XCTFail("The ukAnnualInsurance preset is missing")
            return
        }
        XCTAssertEqual(preset.notice.value, 0)
        XCTAssertEqual(preset.renewalMonths, 12)
        let policy = contract(day(2025, 10, 1), months: preset.renewalMonths, notice: preset.notice)
        let planned = deadlines(contractItem(policy), today: day(2026, 9, 25))
        XCTAssertEqual(planned.map { $0.kind }, [DeadlineKind.termEnd])
        XCTAssertEqual(planned.first?.date, day(2026, 10, 1))
        XCTAssertEqual(planned.first?.remindByDefault, true)
        XCTAssertEqual(planned.first?.offsets ?? [], [30, 7])
        XCTAssertEqual(ContractMath.status(policy, today: day(2026, 9, 25), postalBufferDays: 5).skippedTerms, 1)
    }

    func testRuleBookTolerantDecoding() {
        let defaults = RuleBook.defaults
        // Nothing stored, or nothing readable: the defaults.
        XCTAssertEqual(RuleBook.decode(nil), defaults)
        XCTAssertEqual(RuleBook.decode(Data()), defaults)
        XCTAssertEqual(RuleBook.decode(Data("not json".utf8)), defaults)
        XCTAssertEqual(RuleBook.decode(Data("[1, 2, 3]".utf8)), defaults)
        XCTAssertEqual(RuleBook.decode(Data(#"{"postalBufferDays": "five"}"#.utf8)), defaults)
        XCTAssertEqual(RuleBook.decode(Data(#"{"rules": {"englandWales": "oops"}}"#.utf8)), defaults)
        XCTAssertEqual(RuleBook.decode(defaults.encoded()), defaults)

        // Unknown keys, jurisdictions and kinds are ignored; null keeps the default.
        let unknown = #"{"futureSetting": {"a": 1}, "rules": {"mars": {"returnDaysStore": 1}, "eu": {"futureDays": 3}}, "offsets": {"notAKind": [1]}, "postalBufferDays": null}"#
        XCTAssertEqual(RuleBook.decode(Data(unknown.utf8)), defaults)

        // A partial object keeps every value it does not name.
        let partial = #"{"rules": {"englandWales": {"returnDaysStore": 35}}, "offsets": {"returnWindow": [7]}, "postalBufferDays": 3, "minReminderMinor": 5000}"#
        let book = RuleBook.decode(Data(partial.utf8))
        XCTAssertEqual(book.rules(for: .englandWales).returnDaysStore, 35)
        XCTAssertEqual(book.rules(for: .englandWales).rightToRejectDays, 30)
        XCTAssertEqual(book.rules(for: .switzerland), defaults.rules(for: .switzerland))
        XCTAssertEqual(book.offsets(for: .returnWindow), [7])
        XCTAssertEqual(book.offsets(for: .cancellation), [3, 1])
        XCTAssertNil(book.offsets["notAKind"])
        XCTAssertEqual(book.postalBufferDays, 3)
        XCTAssertEqual(book.minReminderMinor, 5000)
        XCTAssertEqual(book.presets, defaults.presets)
        XCTAssertEqual(book.remindByDefault, defaults.remindByDefault)
        XCTAssertEqual(RuleBook.decode(book.encoded()), book)

        // A stored preset needs only its id.
        let presets = #"{"presets": [{"id": "custom", "renewalMonths": 6}]}"#
        let custom = RuleBook.decode(Data(presets.utf8)).preset(id: "custom")
        XCTAssertEqual(custom?.renewalMonths, 6)
        XCTAssertEqual(custom?.notice, NoticePeriod(value: 3, unit: .months))
    }

    func testRuleBookDefaults() {
        let book = RuleBook.defaults
        func values(_ j: Jurisdiction) -> [Int] {
            RuleField.allCases.map { book.rules(for: j).value($0) }
        }
        // Store return / online cancel / doorstep cancel / reject / fault / legal
        // guarantee / used goods / claim limit / manufacturer warranty.
        XCTAssertEqual(values(.englandWales), [28, 14, 14, 30, 6, 0, 0, 6, 12])
        XCTAssertEqual(values(.scotland), [28, 14, 14, 30, 6, 0, 0, 5, 12])
        XCTAssertEqual(values(.switzerland), [14, 0, 14, 0, 0, 24, 12, 0, 0])
        XCTAssertEqual(values(.eu), [14, 14, 14, 0, 12, 24, 12, 0, 12])
        XCTAssertEqual(book.rules.count, Jurisdiction.allCases.count)

        let expectedOffsets: [[Int]] = [[3, 1], [3, 1], [5, 1], [30], [30, 7], [30], [90], [30, 14, 3], [30, 7], [7]]
        let actualOffsets: [[Int]] = DeadlineKind.allCases.map { book.offsets(for: $0) }
        XCTAssertEqual(actualOffsets, expectedOffsets)
        XCTAssertEqual(DeadlineKind.allCases.filter { book.remindByDefault[$0.rawValue] == true },
                       [DeadlineKind.returnWindow, .cancellation, .manufacturerWarranty, .legalGuarantee,
                        .noticeDeadline, .custom])
        XCTAssertEqual(book.remindByDefault.count, DeadlineKind.allCases.count)
        XCTAssertEqual(book.minReminderMinor, 0)
        XCTAssertEqual(book.postalBufferDays, 5)

        XCTAssertEqual(book.presets.map { $0.id },
                       ["chInsuranceVVG", "chHealthKVG", "chRental", "mobileInternetCH", "mobileInternetUK",
                        "subscriptionMonthly", "deAfterMinimum", "ukAnnualInsurance", "custom"])
        XCTAssertEqual(book.preset(id: "chInsuranceVVG")?.notice, NoticePeriod(value: 3, unit: .months))
        XCTAssertEqual(book.preset(id: "chRental")?.notice, NoticePeriod(value: 3, unit: .months))
        XCTAssertEqual(book.preset(id: "mobileInternetCH")?.notice, NoticePeriod(value: 2, unit: .months))
        XCTAssertEqual(book.preset(id: "mobileInternetUK")?.notice, NoticePeriod(value: 30, unit: .days))
        XCTAssertEqual(book.preset(id: "mobileInternetUK")?.renewalMonths, 1)
        XCTAssertEqual(book.preset(id: "subscriptionMonthly")?.renewalMonths, 1)
        XCTAssertEqual(book.preset(id: "deAfterMinimum")?.notice, NoticePeriod(value: 1, unit: .months))
        XCTAssertEqual(book.preset(id: "custom")?.renewalMonths, 12)
        for id in ["chInsuranceVVG", "chHealthKVG", "chRental", "mobileInternetCH", "mobileInternetUK", "deAfterMinimum"] {
            XCTAssertEqual(book.preset(id: id)?.isAssumption, true, id)
        }
        XCTAssertTrue(book.presets.allSatisfy { !$0.name.isEmpty && !$0.note.isEmpty })
        XCTAssertNil(book.preset(id: "nope"))

        // value and set agree for every field.
        var rules = book.rules(for: .eu)
        for (i, field) in RuleField.allCases.enumerated() {
            rules.set(field, 100 + i)
            XCTAssertEqual(rules.value(field), 100 + i, field.rawValue)
        }
        XCTAssertEqual(RuleField.allCases.map { rules.value($0) }, Array(100..<109))
    }

    func testEveryFieldHasBasisAndShopPolicyIsAssumption() {
        for j in Jurisdiction.allCases {
            for field in RuleField.allCases {
                XCTAssertFalse(RuleBases.basis(field, j).basis.isEmpty, "\(field.rawValue) \(j.rawValue)")
            }
            XCTAssertEqual(RuleBases.basis(.returnDaysStore, j),
                           RuleBasis(basis: "Typical shop policy, not a legal right", isAssumption: true))
        }
        XCTAssertEqual(RuleBases.basis(.rightToRejectDays, .englandWales),
                       RuleBasis(basis: "Consumer Rights Act 2015, s.22", isAssumption: false))
        XCTAssertEqual(RuleBases.basis(.legalGuaranteeMonths, .switzerland),
                       RuleBasis(basis: "OR Art. 210 (2 years since 2013); sellers may limit it in their terms (OR Art. 199)",
                                 isAssumption: false))
        XCTAssertEqual(RuleBases.basis(.faultPresumptionMonths, .eu),
                       RuleBasis(basis: "Directive (EU) 2019/771 Art. 11, minimum; some countries 24 months", isAssumption: true))
        XCTAssertEqual(RuleBases.basis(.claimLimitYears, .scotland),
                       RuleBasis(basis: "Prescription and Limitation (Scotland) Act 1973; start date simplified",
                                 isAssumption: true))
        XCTAssertEqual(RuleBases.basis(.claimLimitYears, .englandWales),
                       RuleBasis(basis: "Limitation Act 1980 s.5; Northern Ireland assumed the same", isAssumption: false))
        XCTAssertTrue(RuleBases.basis(.usedGoodsGuaranteeMonths, .switzerland).isAssumption)
        XCTAssertTrue(RuleBases.basis(.manufacturerWarrantyMonths, .englandWales).isAssumption)

        // Every field can be edited, and every default fits its range.
        let units = Set(["days", "months", "years"])
        for field in RuleField.allCases {
            XCTAssertFalse(field.label.isEmpty, field.rawValue)
            XCTAssertTrue(units.contains(field.unit), field.rawValue)
            for j in Jurisdiction.allCases {
                XCTAssertLessThanOrEqual(RuleBook.defaults.rules(for: j).value(field), field.maxValue, field.rawValue)
            }
        }
        XCTAssertEqual(Set(RuleField.allCases.map { $0.label }).count, RuleField.allCases.count)
    }

    func testDisclaimerNotEmpty() {
        XCTAssertFalse(LegalNotes.disclaimer.isEmpty)
        XCTAssertTrue(LegalNotes.disclaimer.contains("not legal advice"))
        for j in Jurisdiction.allCases {
            for channel in PurchaseChannel.allCases {
                for kind in ItemKind.allCases {
                    for hasIssue in [false, true] {
                        for isUsed in [false, true] {
                            let notes = LegalNotes.notes(for: j, channel: channel, kind: kind, hasIssue: hasIssue, isUsed: isUsed)
                            let label = "\(j.rawValue) \(channel.rawValue) \(kind.rawValue)"
                            XCTAssertFalse(notes.isEmpty, label)
                            XCTAssertTrue(notes.allSatisfy { !$0.text.isEmpty && !$0.basis.isEmpty }, label)
                        }
                    }
                }
            }
        }
    }

    /// Every combination with the built-in rules: sorted, one entry per kind,
    /// law or assumption with a basis, lead times largest first.
    func testEveryDefaultPlanIsSortedWithOneEntryPerKind() {
        for j in Jurisdiction.allCases {
            for channel in PurchaseChannel.allCases {
                for category in ProductCategory.allCases {
                    for isUsed in [false, true] {
                        var f = facts(j, bought: day(2024, 3, 12), delivered: day(2024, 3, 15),
                                      channel: channel, category: category)
                        f.isUsed = isUsed
                        let planned = deadlines(f)
                        let label = "\(j.rawValue) \(channel.rawValue) \(category.rawValue) used: \(isUsed)"
                        XCTAssertEqual(Set(planned.map { $0.kind }).count, planned.count, label)
                        XCTAssertTrue(zip(planned, planned.dropFirst()).allSatisfy { pair in pair.0.date <= pair.1.date }, label)
                        XCTAssertTrue(planned.allSatisfy { $0.certainty == .law || $0.certainty == .assumption }, label)
                        XCTAssertTrue(planned.allSatisfy { !$0.basis.isEmpty && $0.offsets == $0.offsets.sorted(by: >) }, label)
                        XCTAssertTrue(planned.allSatisfy { $0.date > f.purchaseDate }, label)
                        if !category.tracksGoodsDates {
                            XCTAssertTrue(planned.isEmpty, label)
                        }
                    }
                }
            }
        }
    }

    // MARK: - ReminderPlanner

    func testOffsetsBecomeReminders() {
        let deadline = input("d1", item: "i1", date: day(2025, 6, 10), offsets: [7, 1])
        let planned = reminders([deadline], today: day(2025, 5, 1))
        XCTAssertEqual(planned.map { $0.fireDay }, [day(2025, 6, 3), day(2025, 6, 9)])
        XCTAssertEqual(planned.map { $0.identifier }, ["rv.d1.7", "rv.d1.1"])
        XCTAssertEqual(planned.map { $0.title }, ["Return window closes in 7 days", "Return window closes tomorrow"])
        XCTAssertTrue(planned.allSatisfy { $0.hour == 9 && $0.minute == 0 && $0.itemID == "i1" })
        XCTAssertEqual(planned.first?.body, "Sony WH-1000XM5 · Currys · 2025-06-10")

        // The user's reminder time is used as given.
        let evening = reminders([deadline], today: day(2025, 5, 1), hour: 18, minute: 30)
        XCTAssertEqual(evening.map { $0.fireDay }, [day(2025, 6, 3), day(2025, 6, 9)])
        XCTAssertTrue(evening.allSatisfy { $0.hour == 18 && $0.minute == 30 })
    }

    func testPastDroppedIncludingEarlierToday() {
        let deadline = input("d1", item: "i1", date: day(2025, 6, 10), offsets: [7, 1, 0])
        // 10:00 with reminders at 09:00: today's 7-day reminder has gone.
        let late = reminders([deadline], today: day(2025, 6, 3), now: 10 * 60, hour: 9)
        XCTAssertEqual(late.map { $0.identifier }, ["rv.d1.1", "rv.d1.0"])
        XCTAssertEqual(late.map { $0.fireDay }, [day(2025, 6, 9), day(2025, 6, 10)])
        // 09:00 exactly has gone too.
        XCTAssertEqual(reminders([deadline], today: day(2025, 6, 3), now: 9 * 60, hour: 9).map { $0.identifier },
                       ["rv.d1.1", "rv.d1.0"])
        // At 08:00 it still fires today.
        let early = reminders([deadline], today: day(2025, 6, 3), now: 8 * 60, hour: 9)
        XCTAssertEqual(early.map { $0.identifier }, ["rv.d1.7", "rv.d1.1", "rv.d1.0"])
        XCTAssertEqual(early.first?.fireDay, day(2025, 6, 3))

        // A deadline that has passed, or is today after the reminder time, gives nothing.
        let passed = input("old", item: "i1", date: day(2025, 6, 2), offsets: [7, 1])
        XCTAssertTrue(reminders([passed], today: day(2025, 6, 3)).isEmpty)
        let endsToday = input("now", item: "i1", date: day(2025, 6, 3), offsets: [1])
        XCTAssertTrue(reminders([endsToday], today: day(2025, 6, 3), now: 10 * 60).isEmpty)
    }

    func testLateAddGetsOne() {
        // Due in 2 days with lead times of 30 and 7, at 10:00: one reminder, tomorrow.
        let deadline = input("d1", item: "i1", date: day(2025, 6, 10), offsets: [30, 7])
        let late = reminders([deadline], today: day(2025, 6, 8), now: 10 * 60)
        XCTAssertEqual(late.count, 1)
        XCTAssertEqual(late.first?.fireDay, day(2025, 6, 9))
        XCTAssertEqual(late.first?.identifier, "rv.d1.1")
        XCTAssertEqual(late.first?.title, "Return window closes tomorrow")

        // Before the reminder time, it fires today instead.
        let early = reminders([deadline], today: day(2025, 6, 8), now: 8 * 60)
        XCTAssertEqual(early.map { $0.fireDay }, [day(2025, 6, 8)])
        XCTAssertEqual(early.first?.title, "Return window closes in 2 days")

        // Nothing when the next possible time is after the deadline.
        XCTAssertTrue(reminders([deadline], today: day(2025, 6, 10), now: 10 * 60).isEmpty)

        // A lead time still ahead means no extra reminder.
        let ahead = reminders([input("d2", item: "i2", date: day(2025, 6, 10), offsets: [30, 1])],
                              today: day(2025, 6, 8), now: 10 * 60)
        XCTAssertEqual(ahead.map { $0.identifier }, ["rv.d2.1"])
    }

    func testSameItemSameDayMerged() {
        let inputs = [
            input("ret", item: "i1", date: day(2025, 6, 10), offsets: [3]),
            input("can", item: "i1", kind: .cancellation, date: day(2025, 6, 12), offsets: [5, 1]),
            input("other", item: "i2", date: day(2025, 6, 10), offsets: [3], title: "Kettle", merchant: "Argos"),
        ]
        let planned = reminders(inputs, today: day(2025, 6, 1))
        XCTAssertEqual(planned.map { $0.identifier }, ["rv.m.i1.2025-06-07", "rv.other.3", "rv.can.1"])

        let merged = planned.first(where: { $0.identifier == "rv.m.i1.2025-06-07" })
        XCTAssertEqual(merged?.title, "2 dates for Sony WH-1000XM5")
        XCTAssertEqual(merged?.itemID, "i1")
        XCTAssertEqual(merged?.fireDay, day(2025, 6, 7))
        XCTAssertTrue(merged?.body.contains("Return window closes in 3 days") ?? false, merged?.body ?? "")

        // Another item on the same day keeps its own reminder.
        let kettle = planned.first(where: { $0.identifier == "rv.other.3" })
        XCTAssertEqual(kettle?.fireDay, day(2025, 6, 7))
        XCTAssertEqual(kettle?.body, "Kettle · Argos · 2025-06-10")
        XCTAssertEqual(planned.filter { $0.itemID == "i1" }.count, 2)
    }

    func testCapWithRefresh() {
        let start = day(2025, 7, 1)
        let inputs = (0..<100).reversed().map { n in
            input("d\(n)", item: "i\(n)", date: RVCalendar.adding(days: n, to: start), offsets: [1])
        }
        let planned = reminders(inputs, today: day(2025, 6, 1))
        XCTAssertEqual(ReminderPlanner.limit, 60)
        XCTAssertEqual(planned.count, 60)
        XCTAssertEqual(planned.last?.identifier, "rv.refresh")
        XCTAssertEqual(planned.filter { $0.identifier == "rv.refresh" }.count, 1)

        // The soonest 59, in order.
        let kept = planned.filter { $0.identifier != "rv.refresh" }
        XCTAssertEqual(kept.count, 59)
        XCTAssertEqual(kept.map { $0.fireDay }, (0..<59).map { RVCalendar.adding(days: $0, to: day(2025, 6, 30)) })

        // The refresh fires on the last kept day.
        let refresh = planned.last
        XCTAssertEqual(refresh?.fireDay, kept.last?.fireDay)
        XCTAssertEqual(refresh?.itemID, "")
        XCTAssertTrue(refresh?.body.contains("keep your reminders up to date") ?? false, refresh?.body ?? "")

        // At the limit, nothing is dropped and there is no refresh.
        let sixty = reminders(Array(inputs.suffix(60)), today: day(2025, 6, 1))
        XCTAssertEqual(sixty.count, 60)
        XCTAssertFalse(sixty.contains(where: { $0.identifier == "rv.refresh" }))

        // A smaller limit: limit − 1 plus the refresh.
        let small = reminders(inputs, today: day(2025, 6, 1), limit: 5)
        XCTAssertEqual(small.map { $0.identifier }, ["rv.d0.1", "rv.d1.1", "rv.d2.1", "rv.d3.1", "rv.refresh"])
    }

    func testIdentifiersStableAndUnique() {
        let inputs = [
            input("ret", item: "i1", date: day(2025, 6, 10), offsets: [30, 7, 1, 1]),
            input("war", item: "i1", kind: .manufacturerWarranty, date: day(2025, 6, 10), offsets: [30, 7]),
            input("kvg", item: "c1", kind: .noticeDeadline, date: day(2025, 11, 30), offsets: [30, 14, 7, 3]),
        ]
        let planned = reminders(inputs, today: day(2025, 5, 1))
        // Running it again, or in another order, changes nothing.
        XCTAssertEqual(reminders(inputs, today: day(2025, 5, 1)), planned)
        XCTAssertEqual(reminders(Array(inputs.reversed()), today: day(2025, 5, 1)), planned)

        let ids = planned.map { $0.identifier }
        XCTAssertEqual(ids, ["rv.m.i1.2025-05-11", "rv.m.i1.2025-06-03", "rv.ret.1",
                             "rv.kvg.30", "rv.kvg.14", "rv.kvg.7", "rv.kvg.3"])
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix(ReminderPlanner.prefix) })

        // A later run keeps the identifiers of the reminders still ahead.
        let later = reminders(inputs, today: day(2025, 5, 20)).map { $0.identifier }
        XCTAssertEqual(later, ["rv.m.i1.2025-06-03", "rv.ret.1", "rv.kvg.30", "rv.kvg.14", "rv.kvg.7", "rv.kvg.3"])
        XCTAssertTrue(Set(later).isSubset(of: Set(ids)))

        // The same deadline given twice still gives unique identifiers.
        let doubled = reminders(inputs + inputs, today: day(2025, 5, 1)).map { $0.identifier }
        XCTAssertEqual(Set(doubled).count, doubled.count)
    }

    func testPrivateTextHidesNames() {
        let inputs = [
            input("ret", item: "i1", date: day(2025, 6, 10), offsets: [3]),
            input("war", item: "i1", kind: .manufacturerWarranty, date: day(2025, 6, 10), offsets: [3]),
            input("own", item: "i2", kind: .custom, date: day(2025, 6, 20), offsets: [7],
                  title: "Boiler", merchant: "British Gas", label: "Boiler service"),
        ]
        let hidden = reminders(inputs, today: day(2025, 6, 1), privateText: true)
        XCTAssertEqual(hidden.count, 2)
        for r in hidden {
            XCTAssertEqual(r.title, ReminderPlanner.privateTitle)
            XCTAssertEqual(r.body, ReminderPlanner.privateBody)
            for word in ["Sony", "Currys", "Boiler", "British Gas", "Return", "2025"] {
                XCTAssertFalse(r.title.contains(word) || r.body.contains(word), word)
            }
        }
        XCTAssertEqual(ReminderPlanner.privateTitle, "A deadline is coming up")
        XCTAssertEqual(ReminderPlanner.privateBody, "Open ReceiptVault to see what is due.")

        // Identifiers and days are the same with detailed text.
        let shown = reminders(inputs, today: day(2025, 6, 1))
        XCTAssertEqual(shown.map { $0.identifier }, hidden.map { $0.identifier })
        XCTAssertEqual(shown.map { $0.fireDay }, hidden.map { $0.fireDay })
        XCTAssertEqual(shown.map { $0.title }, ["2 dates for Sony WH-1000XM5", "Boiler service in 7 days"])
    }

    func testNoAmountsInText() {
        let title = "Sony WH-1000XM5 £299.00"
        let shop = "Digitec CHF 1'299.\u{2013}"
        let inputs = [
            input("ret", item: "i1", date: day(2025, 6, 10), offsets: [3], title: title, merchant: shop),
            input("war", item: "i1", kind: .manufacturerWarranty, date: day(2025, 6, 10), offsets: [3],
                  title: title, merchant: shop),
            input("dep", item: "i2", kind: .custom, date: day(2025, 6, 20), offsets: [7],
                  title: "Flat deposit", merchant: "€ 480,00", label: "Deposit 480.00 back"),
        ]
        let planned = reminders(inputs, today: day(2025, 6, 1))
        XCTAssertEqual(planned.count, 2)
        for r in planned {
            for amount in ["299", "480", "£", "€", "CHF"] {
                XCTAssertFalse(r.title.contains(amount) || r.body.contains(amount), "\(amount) in \(r.title) / \(r.body)")
            }
        }
        XCTAssertEqual(planned.first?.title, "2 dates for Sony WH-1000XM5")
        XCTAssertEqual(planned.last?.title, "Deposit back in 7 days")
        XCTAssertEqual(planned.last?.body, "Flat deposit · 2025-06-20")

        let single = ReminderPlanner.body(itemTitle: title, merchant: "Currys", date: day(2024, 4, 9))
        XCTAssertFalse(single.contains("299"), single)
        XCTAssertFalse(single.contains("£"), single)
        XCTAssertTrue(single.hasPrefix("Sony WH-1000XM5"), single)
    }

    func testTitlesTodayTomorrowInNDays() {
        XCTAssertEqual(ReminderPlanner.title(kind: .returnWindow, label: "", daysLeft: 3), "Return window closes in 3 days")
        XCTAssertEqual(ReminderPlanner.title(kind: .returnWindow, label: "", daysLeft: 1), "Return window closes tomorrow")
        XCTAssertEqual(ReminderPlanner.title(kind: .returnWindow, label: "", daysLeft: 0), "Return window closes today")
        XCTAssertEqual(ReminderPlanner.title(kind: .noticeDeadline, label: "", daysLeft: 7), "Notice must arrive in 7 days")
        XCTAssertEqual(ReminderPlanner.title(kind: .custom, label: "Boiler service", daysLeft: 3), "Boiler service in 3 days")
        XCTAssertEqual(ReminderPlanner.title(kind: .custom, label: "Boiler service", daysLeft: 1), "Boiler service tomorrow")
        // The label is used only for custom dates.
        XCTAssertEqual(ReminderPlanner.title(kind: .returnWindow, label: "Ignored", daysLeft: 3), "Return window closes in 3 days")
        for kind in DeadlineKind.allCases {
            XCTAssertTrue(ReminderPlanner.title(kind: kind, label: "", daysLeft: 5).hasSuffix(" in 5 days"), kind.rawValue)
            XCTAssertTrue(ReminderPlanner.title(kind: kind, label: "", daysLeft: 1).hasSuffix(" tomorrow"), kind.rawValue)
            XCTAssertTrue(ReminderPlanner.title(kind: kind, label: "", daysLeft: 0).hasSuffix(" today"), kind.rawValue)
        }
        XCTAssertEqual(ReminderPlanner.body(itemTitle: "Sony WH-1000XM5", merchant: "Currys", date: day(2024, 4, 9)),
                       "Sony WH-1000XM5 · Currys · 2024-04-09")
    }

    func testBackupReminderAfter30Days() {
        let due = ReminderPlanner.backupReminder(lastBackup: day(2025, 6, 1), everyDays: 30, today: day(2025, 6, 10),
                                                 nowMinutes: 8 * 60, hour: 9, minute: 0)
        XCTAssertEqual(due?.identifier, "rv.backup")
        XCTAssertEqual(due?.itemID, "")
        XCTAssertEqual(due?.fireDay, day(2025, 7, 1))
        XCTAssertEqual(due?.hour, 9)
        XCTAssertEqual(due?.minute, 0)
        XCTAssertFalse(due?.title.isEmpty ?? true)
        XCTAssertTrue(due?.identifier.hasPrefix(ReminderPlanner.prefix) ?? false)

        // Overdue: the next possible time, today or tomorrow.
        let overdueEarly = ReminderPlanner.backupReminder(lastBackup: day(2025, 4, 1), everyDays: 30, today: day(2025, 6, 10),
                                                          nowMinutes: 8 * 60, hour: 9, minute: 0)
        XCTAssertEqual(overdueEarly?.fireDay, day(2025, 6, 10))
        let overdueLate = ReminderPlanner.backupReminder(lastBackup: day(2025, 4, 1), everyDays: 30, today: day(2025, 6, 10),
                                                         nowMinutes: 10 * 60, hour: 9, minute: 0)
        XCTAssertEqual(overdueLate?.fireDay, day(2025, 6, 11))

        // Never backed up: as soon as possible.
        let never = ReminderPlanner.backupReminder(lastBackup: nil, everyDays: 30, today: day(2025, 6, 10),
                                                   nowMinutes: 10 * 60, hour: 9, minute: 0)
        XCTAssertEqual(never?.fireDay, day(2025, 6, 11))

        // Turned off.
        XCTAssertNil(ReminderPlanner.backupReminder(lastBackup: day(2025, 6, 1), everyDays: 0, today: day(2025, 6, 10),
                                                    nowMinutes: 8 * 60, hour: 9, minute: 0))
        XCTAssertNil(ReminderPlanner.backupReminder(lastBackup: day(2025, 6, 1), everyDays: -1, today: day(2025, 6, 10),
                                                    nowMinutes: 8 * 60, hour: 9, minute: 0))

        // 59 reminders, the refresh and the backup stay under iOS's 64 pending.
        XCTAssertLessThan(ReminderPlanner.limit + 1, 64)
    }
}
