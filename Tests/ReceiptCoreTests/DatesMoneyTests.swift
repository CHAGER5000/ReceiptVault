import Foundation
import XCTest
@testable import ReceiptCore

/// Vocabulary, Dates, Money, TextLayout and Lexicon. Fixed dates only (never
/// Date() for today), and never Money.format, whose ICU output differs by platform.
final class DatesMoneyTests: XCTestCase {
    /// One line: cells given as (text, left, right) in page fractions.
    private func line(_ y: Double, _ cells: [(String, Double, Double)], height: Double = 0.02) -> TextLine {
        TextLine(page: 0, y: y, cells: cells.map { TextCell(text: $0.0, x0: $0.1, x1: $0.2) }, height: height)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> DayDate {
        DayDate(year: y, month: m, day: d)
    }

    /// The dates DateFinder finds in `text`, without positions.
    private func found(_ text: String, dayFirst: Bool = true) -> [DayDate] {
        DateFinder.dates(in: text, dayFirst: dayFirst).map { $0.date }
    }

    // MARK: - Vocabulary

    /// Raw values are persisted in SwiftData, settings and backups: renaming one loses data.
    func testRawValuesAreFrozen() throws {
        XCTAssertEqual(ItemKind.allCases.map { $0.rawValue }, ["receipt", "invoice", "warranty", "contract"])
        XCTAssertEqual(Jurisdiction.allCases.map { $0.rawValue }, ["englandWales", "scotland", "switzerland", "eu"])
        XCTAssertEqual(PurchaseChannel.allCases.map { $0.rawValue }, ["store", "online", "doorstep"])
        XCTAssertEqual(ProductCategory.allCases.map { $0.rawValue },
                       ["electronics", "appliance", "furniture", "clothing", "homeGarden", "sportLeisure",
                        "vehicle", "otherGoods", "groceries", "service", "expense"])
        XCTAssertEqual(DeadlineKind.allCases.map { $0.rawValue },
                       ["returnWindow", "cancellation", "rightToReject", "faultPresumption", "manufacturerWarranty",
                        "legalGuarantee", "claimLimit", "noticeDeadline", "termEnd", "custom"])
        XCTAssertEqual(Certainty.allCases.map { $0.rawValue }, ["law", "assumption", "printed", "user"])
        XCTAssertEqual(TaxTag.allCases.map { $0.rawValue }, ["none", "uk", "ch", "both"])
        XCTAssertEqual(FileSource.allCases.map { $0.rawValue }, ["scan", "photos", "files", "openIn", "restored"])
        XCTAssertEqual(NoticePeriod.Unit.allCases.map { $0.rawValue }, ["days", "weeks", "months"])

        // Raw values read back to the same cases.
        XCTAssertEqual(ItemKind(rawValue: "warranty"), ItemKind.warranty)
        XCTAssertEqual(DeadlineKind(rawValue: "noticeDeadline"), DeadlineKind.noticeDeadline)
        XCTAssertEqual(FileSource(rawValue: "openIn"), FileSource.openIn)
        XCTAssertNil(ProductCategory(rawValue: "Electronics"))

        // Notice periods are stored as JSON in backups.
        let json = #"{"value":3,"unit":"months"}"#
        let period = try JSONDecoder().decode(NoticePeriod.self, from: Data(json.utf8))
        XCTAssertEqual(period, NoticePeriod(value: 3, unit: .months))
    }

    func testTaxTagMatchesLocalLedger() {
        XCTAssertEqual(TaxTag.allCases.map { $0.rawValue }, ["none", "uk", "ch", "both"])
        XCTAssertEqual(TaxTag.allCases.map { $0.label }, ["Not claimable", "UK", "Switzerland", "UK and Switzerland"])
        XCTAssertEqual(TaxTag.allCases.map { $0.id }, ["none", "uk", "ch", "both"])
        XCTAssertEqual(TaxTag(rawValue: "ch"), TaxTag.ch)
    }

    func testNoticePeriodLabels() {
        XCTAssertEqual(NoticePeriod(value: 3, unit: .months).label, "3 months")
        XCTAssertEqual(NoticePeriod(value: 1, unit: .months).label, "1 month")
        XCTAssertEqual(NoticePeriod(value: 30, unit: .days).label, "30 days")
        XCTAssertEqual(NoticePeriod(value: 1, unit: .weeks).label, "1 week")
        XCTAssertEqual(NoticePeriod(value: 0, unit: .months).label, "No notice")
        XCTAssertEqual(NoticePeriod(value: 0, unit: .days).label, "No notice")
    }

    func testCategoryFlags() {
        XCTAssertEqual(ProductCategory.allCases.filter { !$0.tracksGoodsDates },
                       [ProductCategory.groceries, .service, .expense])
        XCTAssertEqual(ProductCategory.allCases.filter { $0.usesManufacturerDefault },
                       [ProductCategory.electronics, .appliance])
        XCTAssertTrue(ProductCategory.furniture.tracksGoodsDates)
        XCTAssertFalse(ProductCategory.furniture.usesManufacturerDefault)
    }

    func testJurisdictionCurrenciesAreSupported() {
        XCTAssertEqual(Jurisdiction.allCases.map { $0.defaultCurrency }, ["GBP", "GBP", "CHF", "EUR"])
        for j in Jurisdiction.allCases {
            XCTAssertTrue(Money.supportedCurrencies.contains(j.defaultCurrency), j.rawValue)
        }
    }

    /// Every case has a label (and a symbol where there is one), and no two
    /// cases of one enum share a label.
    func testEveryCaseHasADistinctLabel() {
        let labelLists: [[String]] = [
            ItemKind.allCases.map { $0.label },
            Jurisdiction.allCases.map { $0.label },
            PurchaseChannel.allCases.map { $0.label },
            ProductCategory.allCases.map { $0.label },
            DeadlineKind.allCases.map { $0.label },
            DeadlineKind.allCases.map { $0.dueWording },
            Certainty.allCases.map { $0.label },
            TaxTag.allCases.map { $0.label },
            FileSource.allCases.map { $0.label },
        ]
        for labels in labelLists {
            XCTAssertFalse(labels.contains(where: { $0.isEmpty }), "\(labels)")
            XCTAssertEqual(Set(labels).count, labels.count, "\(labels)")
        }
        let itemSymbols: [String] = ItemKind.allCases.map { $0.symbol }
        let deadlineSymbols: [String] = DeadlineKind.allCases.map { $0.symbol }
        let symbols: [String] = itemSymbols + deadlineSymbols
        XCTAssertFalse(symbols.contains(where: { $0.isEmpty }))
    }

    // MARK: - Dates

    func testMonthArithmeticClamps() {
        XCTAssertEqual(RVCalendar.adding(months: 1, to: day(2024, 1, 31)), day(2024, 2, 29))
        XCTAssertEqual(RVCalendar.adding(months: 24, to: day(2024, 2, 29)), day(2026, 2, 28))
        XCTAssertEqual(RVCalendar.adding(months: -1, to: day(2025, 3, 31)), day(2025, 2, 28))
        XCTAssertEqual(RVCalendar.adding(months: -1, to: day(2024, 1, 15)), day(2023, 12, 15))
        XCTAssertEqual(RVCalendar.adding(months: 11, to: day(2024, 3, 12)), day(2025, 2, 12))
        XCTAssertEqual(RVCalendar.adding(years: 1, to: day(2024, 2, 29)), day(2025, 2, 28))
        XCTAssertEqual(RVCalendar.adding(years: 2, to: day(2024, 3, 12)), day(2026, 3, 12))
    }

    /// Day periods end on start + days; month periods end the day before the anniversary.
    func testPeriodEndConvention() {
        let start = day(2024, 3, 12)
        XCTAssertEqual(RVCalendar.periodEnd(from: start, days: 28), day(2024, 4, 9))
        XCTAssertEqual(RVCalendar.periodEnd(from: start, days: 30), day(2024, 4, 11))
        XCTAssertEqual(RVCalendar.periodEnd(from: start, months: 6), day(2024, 9, 11))
        XCTAssertEqual(RVCalendar.periodEnd(from: start, months: 12), day(2025, 3, 11))
        XCTAssertEqual(RVCalendar.periodEnd(from: start, months: 72), day(2030, 3, 11))
        XCTAssertEqual(RVCalendar.periodEnd(from: day(2024, 1, 31), months: 1), day(2024, 2, 28))
    }

    func testStoredDateRoundTripAndDaysBetween() {
        let base = day(2024, 3, 12)
        let stored = RVCalendar.date(base)
        XCTAssertEqual(stored.timeIntervalSince1970, 1_710_201_600) // 2024-03-12T00:00:00Z
        XCTAssertEqual(RVCalendar.utc.date(from: DateComponents(year: 2024, month: 3, day: 12)), stored)
        XCTAssertEqual(RVCalendar.day(stored), base)
        XCTAssertEqual(RVCalendar.day(stored.addingTimeInterval(86_399)), base)
        XCTAssertEqual(RVCalendar.day(stored.addingTimeInterval(-1)), day(2024, 3, 11))

        XCTAssertEqual(RVCalendar.daysBetween(base, day(2025, 3, 12)), 365)
        XCTAssertEqual(RVCalendar.daysBetween(day(2024, 2, 28), day(2024, 3, 1)), 2)
        XCTAssertEqual(RVCalendar.daysBetween(day(2024, 3, 1), day(2024, 2, 28)), -2)
        XCTAssertEqual(RVCalendar.daysBetween(base, base), 0)

        // Same answers as Foundation's Calendar, either side of several leap days.
        for n in stride(from: -1_000, through: 1_000, by: 37) {
            let d = RVCalendar.adding(days: n, to: base)
            XCTAssertEqual(RVCalendar.daysBetween(base, d), n)
            XCTAssertEqual(RVCalendar.day(RVCalendar.date(d)), d)
            XCTAssertEqual(RVCalendar.utc.date(byAdding: .day, value: n, to: stored), RVCalendar.date(d))
            XCTAssertEqual(RVCalendar.utc.component(.weekday, from: RVCalendar.date(d)), RVCalendar.weekday(d))
        }

        XCTAssertEqual(DayDate(iso: "2024-03-12"), base)
        XCTAssertEqual(DayDate(iso: "2024-3-5"), day(2024, 3, 5))
        XCTAssertNil(DayDate(iso: "2024-02-30"))
        XCTAssertNil(DayDate(iso: "12.03.2024"))
        XCTAssertNil(DayDate(iso: "2024-03-12T10:00"))
        XCTAssertEqual(day(2024, 3, 5).iso, "2024-03-05")
        XCTAssertLessThan(day(2024, 3, 12), day(2024, 4, 1))
        XCTAssertLessThan(day(2023, 12, 31), day(2024, 1, 1))
        XCTAssertTrue(RVCalendar.isValid(day(2024, 2, 29)))
        XCTAssertFalse(RVCalendar.isValid(day(2025, 2, 29)))
        XCTAssertFalse(RVCalendar.isValid(day(2024, 4, 31)))
        XCTAssertFalse(RVCalendar.isValid(day(2024, 13, 1)))
    }

    func testTodayUsesTimeZone() {
        let winter = Date(timeIntervalSince1970: 1_735_774_200) // 2025-01-01T23:30:00Z
        XCTAssertEqual(RVCalendar.today(now: winter, timeZone: TimeZone(identifier: "Europe/Zurich")!), day(2025, 1, 2))
        XCTAssertEqual(RVCalendar.today(now: winter, timeZone: TimeZone(identifier: "Europe/London")!), day(2025, 1, 1))

        let summer = Date(timeIntervalSince1970: 1_751_412_600) // 2025-07-01T23:30:00Z, British Summer Time
        XCTAssertEqual(RVCalendar.today(now: summer, timeZone: TimeZone(identifier: "Europe/London")!), day(2025, 7, 2))
        XCTAssertEqual(RVCalendar.today(now: summer, timeZone: TimeZone(identifier: "America/New_York")!), day(2025, 7, 1))
    }

    func testWorkingDays() {
        XCTAssertEqual(RVCalendar.weekday(day(2026, 9, 30)), 4)  // Wednesday
        XCTAssertEqual(RVCalendar.weekday(day(2026, 11, 30)), 2) // Monday
        XCTAssertEqual(RVCalendar.weekday(day(2026, 10, 4)), 1)  // Sunday
        XCTAssertEqual(RVCalendar.subtractingWorkingDays(5, from: day(2026, 9, 30)), day(2026, 9, 23))
        XCTAssertEqual(RVCalendar.subtractingWorkingDays(5, from: day(2026, 11, 30)), day(2026, 11, 23))
        XCTAssertEqual(RVCalendar.subtractingWorkingDays(0, from: day(2026, 10, 4)), day(2026, 10, 2))
        XCTAssertEqual(RVCalendar.subtractingWorkingDays(1, from: day(2026, 11, 30)), day(2026, 11, 27))
        XCTAssertEqual(RVCalendar.subtractingWorkingDays(3, from: day(2026, 9, 30)), day(2026, 9, 25))
        XCTAssertEqual(RVCalendar.subtractingWorkingDays(10, from: day(2026, 10, 3)), day(2026, 9, 18))

        // The week-at-a-time shortcut agrees with stepping back one day at a time.
        for offset in 0..<21 {
            let start = RVCalendar.adding(days: offset, to: day(2026, 9, 1))
            for n in 0...12 {
                var expected = start
                while RVCalendar.weekday(expected) == 1 || RVCalendar.weekday(expected) == 7 {
                    expected = RVCalendar.adding(days: -1, to: expected)
                }
                var left = n
                while left > 0 {
                    expected = RVCalendar.adding(days: -1, to: expected)
                    let w = RVCalendar.weekday(expected)
                    if w != 1 && w != 7 { left -= 1 }
                }
                XCTAssertEqual(RVCalendar.subtractingWorkingDays(n, from: start), expected, "\(start.iso) - \(n)")
            }
        }
    }

    func testDateFinderFormats() {
        let march12 = day(2024, 3, 12)
        let texts = ["12/03/2024", "12.03.24", "2024-03-12", "12 Mar 2024", "12. März 2024", "12 mars 2024",
                     "March 12, 2024", "12 marzo 2024"]
        for text in texts {
            XCTAssertEqual(found(text), [march12], text)
        }
        XCTAssertEqual(found("1er mars 2024"), [day(2024, 3, 1)])
        XCTAssertEqual(found("Rechnung vom 1. Februar 2025, fällig 3.3.2025"), [day(2025, 2, 1), day(2025, 3, 3)])

        XCTAssertEqual(DateFinder.dates(in: "Datum: 05.02.2025 14:32"),
                       [FoundDate(date: day(2025, 2, 5), location: 7, length: 10, hasTime: true)])
        XCTAssertEqual(DateFinder.dates(in: "12/03/2024").first?.hasTime, false)

        // Locations are UTF-16 offsets: the emoji takes two.
        let text = "\u{1F9FE} 12.03.2024"
        let dates = DateFinder.dates(in: text)
        XCTAssertEqual(dates.count, 1)
        if let f = dates.first {
            XCTAssertEqual(f.location, 3)
            XCTAssertEqual(f.length, 10)
            XCTAssertEqual((text as NSString).substring(with: NSRange(location: f.location, length: f.length)), "12.03.2024")
        }
        XCTAssertEqual(DateFinder.months["märz"], 3)
        XCTAssertEqual(DateFinder.months["marzo"], 3)
        XCTAssertEqual(DateFinder.months["dicembre"], 12)
    }

    func testDateFinderRejects() {
        let texts = ["12.50", "3/4", "8.1%", "12:30", "20-00-00", "044 123 45 67", "31.02.2024", "12.03.1985", "TOTAL"]
        for text in texts {
            XCTAssertTrue(found(text).isEmpty, text)
        }
    }

    func testDayFirstUnlessImpossible() {
        XCTAssertEqual(found("03/04/2024"), [day(2024, 4, 3)])
        XCTAssertEqual(found("04/13/2024"), [day(2024, 4, 13)])
        XCTAssertEqual(found("03/04/2024", dayFirst: false), [day(2024, 3, 4)])
        XCTAssertEqual(found("13/04/2024", dayFirst: false), [day(2024, 4, 13)])
    }

    // MARK: - Money

    /// LocalLedger's LedgerCoreTests.testFormats and testMinorUnits, unchanged.
    func testLocalLedgerAmountFormatsStillParse() {
        XCTAssertEqual(AmountParser.parse("12.30"), Decimal(string: "12.30"))
        XCTAssertEqual(AmountParser.parse("-12.30"), Decimal(string: "-12.30"))
        XCTAssertEqual(AmountParser.parse("£1,234.56"), Decimal(string: "1234.56"))
        XCTAssertEqual(AmountParser.parse("12.30 DR"), Decimal(string: "-12.30"))
        XCTAssertEqual(AmountParser.parse("12.30CR"), Decimal(string: "12.30"))
        XCTAssertEqual(AmountParser.parse("(45.00)"), Decimal(string: "-45.00"))
        XCTAssertEqual(AmountParser.parse("1'234.50"), Decimal(string: "1234.50"))
        XCTAssertEqual(AmountParser.parse("CHF 1’234.50"), Decimal(string: "1234.50"))
        XCTAssertEqual(AmountParser.parse("1.234,56"), Decimal(string: "1234.56"))
        XCTAssertEqual(AmountParser.parse("12,50"), Decimal(string: "12.50"))
        XCTAssertEqual(AmountParser.parse("1,234"), Decimal(string: "1234"))
        XCTAssertEqual(AmountParser.parse("12.30-"), Decimal(string: "-12.30"))
        XCTAssertNil(AmountParser.parse(""))
        XCTAssertNil(AmountParser.parse("abc"))
        XCTAssertNil(AmountParser.parse("12-30"))

        XCTAssertEqual(Money.minor(from: Decimal(string: "12.345")!), 1235)
        XCTAssertEqual(Money.minor(from: Decimal(string: "-0.01")!), -1)
        XCTAssertEqual(Money.plain(-123456), "-1234.56")
        XCTAssertEqual(Money.plain(5), "0.05")

        XCTAssertEqual(Money.plain(0), "0.00")
        XCTAssertEqual(Money.plain(124900), "1249.00")
        XCTAssertEqual(Money.decimal(fromMinor: 1250), Decimal(string: "12.50"))
        XCTAssertEqual(Money.supportedCurrencies, ["GBP", "CHF", "EUR", "USD"])
    }

    func testReceiptAmountVariants() {
        XCTAssertEqual(ReceiptAmountParser.parse("£12.50"), ReceiptAmount(minor: 1250, currency: "GBP", isNegative: false))
        XCTAssertEqual(ReceiptAmountParser.parse("12.50 A"), ReceiptAmount(minor: 1250, currency: nil, isNegative: false))
        XCTAssertEqual(ReceiptAmountParser.parse("CHF 1'249.00"), ReceiptAmount(minor: 124900, currency: "CHF", isNegative: false))
        XCTAssertEqual(ReceiptAmountParser.parse("1 249,00 €"), ReceiptAmount(minor: 124900, currency: "EUR", isNegative: false))
        XCTAssertEqual(ReceiptAmountParser.parse("Fr. 12.\u{2013}"), ReceiptAmount(minor: 1200, currency: "CHF", isNegative: false))
        XCTAssertEqual(ReceiptAmountParser.parse("12.-"), ReceiptAmount(minor: 1200, currency: nil, isNegative: false))
        XCTAssertEqual(ReceiptAmountParser.parse("12,--"), ReceiptAmount(minor: 1200, currency: nil, isNegative: false))
        XCTAssertEqual(ReceiptAmountParser.parse("-5.00"), ReceiptAmount(minor: -500, currency: nil, isNegative: true))
        XCTAssertEqual(ReceiptAmountParser.parse("5.00-"), ReceiptAmount(minor: -500, currency: nil, isNegative: true))
        XCTAssertEqual(ReceiptAmountParser.parse("EUR 12,50"), ReceiptAmount(minor: 1250, currency: "EUR", isNegative: false))
        XCTAssertEqual(ReceiptAmountParser.parse("12.50*"), ReceiptAmount(minor: 1250, currency: nil, isNegative: false))
        XCTAssertEqual(ReceiptAmountParser.parse("SFr. 7.90"), ReceiptAmount(minor: 790, currency: "CHF", isNegative: false))
        XCTAssertEqual(ReceiptAmountParser.parse("$9.99"), ReceiptAmount(minor: 999, currency: "USD", isNegative: false))
        XCTAssertEqual(ReceiptAmountParser.parse("1.249,00"), ReceiptAmount(minor: 124900, currency: nil, isNegative: false))
        XCTAssertEqual(ReceiptAmountParser.parse("CHF\u{00A0}1\u{2019}249.50"),
                       ReceiptAmount(minor: 124950, currency: "CHF", isNegative: false))

        XCTAssertEqual(ReceiptAmountParser.normalise("12.-"), "12.00")
        XCTAssertEqual(ReceiptAmountParser.normalise("Fr. 12.\u{2013}"), "Fr. 12.00")
        XCTAssertEqual(ReceiptAmountParser.normalise("1\u{202F}249,00"), "1 249,00")

        XCTAssertEqual(ReceiptAmountParser.currencyCode(forSymbol: "£"), "GBP")
        XCTAssertEqual(ReceiptAmountParser.currencyCode(forSymbol: "GBP"), "GBP")
        XCTAssertEqual(ReceiptAmountParser.currencyCode(forSymbol: "€"), "EUR")
        XCTAssertEqual(ReceiptAmountParser.currencyCode(forSymbol: "EUR"), "EUR")
        XCTAssertEqual(ReceiptAmountParser.currencyCode(forSymbol: "CHF"), "CHF")
        XCTAssertEqual(ReceiptAmountParser.currencyCode(forSymbol: "Fr."), "CHF")
        XCTAssertEqual(ReceiptAmountParser.currencyCode(forSymbol: "SFr."), "CHF")
        XCTAssertEqual(ReceiptAmountParser.currencyCode(forSymbol: "$"), "USD")
        XCTAssertEqual(ReceiptAmountParser.currencyCode(forSymbol: "USD"), "USD")
        XCTAssertNil(ReceiptAmountParser.currencyCode(forSymbol: "XYZ"))
    }

    func testRejectsNonMoney() {
        let tokens = ["3297", "12/03", "20-00-00", "8.1%", "14:32", "044 123 45 67", "1 249.00", "1.249.00", "12.5",
                      "-5.00-", ""]
        for token in tokens {
            XCTAssertNil(ReceiptAmountParser.parse(token), token)
        }
    }

    func testTrailingAmountAndLabel() {
        let total = ReceiptAmountParser.trailing(in: "TOTAL  £249.00")
        XCTAssertEqual(total?.amount, ReceiptAmount(minor: 24900, currency: "GBP", isNegative: false))
        XCTAssertEqual(total?.label, "TOTAL")

        // "1 249.00" is not an amount, so the quantity stays out of it.
        let qty = ReceiptAmountParser.trailing(in: "Qty 1 249.00")
        XCTAssertEqual(qty?.amount.minor, 24900)
        XCTAssertEqual(qty?.label, "Qty 1")

        let colon = ReceiptAmountParser.trailing(in: "Total: 12.50")
        XCTAssertEqual(colon?.amount.minor, 1250)
        XCTAssertEqual(colon?.label, "Total")

        let swiss = ReceiptAmountParser.trailing(in: "Summe CHF 1'249.00")
        XCTAssertEqual(swiss?.amount, ReceiptAmount(minor: 124900, currency: "CHF", isNegative: false))
        XCTAssertEqual(swiss?.label, "Summe")

        let euro = ReceiptAmountParser.trailing(in: "Zwischensumme 1 249,00 €")
        XCTAssertEqual(euro?.amount, ReceiptAmount(minor: 124900, currency: "EUR", isNegative: false))
        XCTAssertEqual(euro?.label, "Zwischensumme")

        XCTAssertNil(ReceiptAmountParser.trailing(in: "Nothing here"))
        XCTAssertNil(ReceiptAmountParser.trailing(in: ""))
    }

    func testAllAmountsInReadingOrder() {
        XCTAssertEqual(ReceiptAmountParser.all(in: "2 x 4.50  9.00 A").map { $0.minor }, [450, 900])
        XCTAssertEqual(ReceiptAmountParser.all(in: "£5.00 and €3.00"),
                       [ReceiptAmount(minor: 500, currency: "GBP", isNegative: false),
                        ReceiptAmount(minor: 300, currency: "EUR", isNegative: false)])
        XCTAssertTrue(ReceiptAmountParser.all(in: "Tel 044 123 45 67, 14:32").isEmpty)
    }

    func testOCRSlipsOnlyWithFromOCR() {
        XCTAssertNil(ReceiptAmountParser.parse("1O.5O"))
        XCTAssertEqual(ReceiptAmountParser.parse("1O.5O", fromOCR: true)?.minor, 1050)
        XCTAssertNil(ReceiptAmountParser.parse("l2.00"))
        XCTAssertEqual(ReceiptAmountParser.parse("l2.00", fromOCR: true)?.minor, 1200)
        XCTAssertNil(ReceiptAmountParser.trailing(in: "TOTAL 1O.5O"))
        XCTAssertEqual(ReceiptAmountParser.trailing(in: "TOTAL 1O.5O", fromOCR: true)?.amount.minor, 1050)
        XCTAssertEqual(ReceiptAmountParser.trailing(in: "TOTAL 1O.5O", fromOCR: true)?.label, "TOTAL")
    }

    func testPercent() {
        XCTAssertEqual(Money.percent(permille: 200), "20")
        XCTAssertEqual(Money.percent(permille: 81), "8.1")
        XCTAssertEqual(Money.percent(permille: 26), "2.6")
        XCTAssertEqual(Money.percent(permille: 25), "2.5")
        XCTAssertEqual(Money.percent(permille: 135), "13.5")
        XCTAssertEqual(Money.percent(permille: 0), "0")
    }

    func testCurrenciesInOrder() {
        XCTAssertEqual(ReceiptAmountParser.currencies(in: "Fr. 12.00 ... EUR"), ["CHF", "EUR"])
        XCTAssertEqual(ReceiptAmountParser.currencies(in: "£5.00 and €3.00"), ["GBP", "EUR"])
        XCTAssertEqual(ReceiptAmountParser.currencies(in: "Total CHF 20.00"), ["CHF"])
        // "Fr." before a date is Freitag, not francs.
        XCTAssertTrue(ReceiptAmountParser.currencies(in: "Fr. 12.03.2025").isEmpty)
    }

    // MARK: - TextLayout

    /// LocalLedger's testLayoutGroupsWordsIntoLinesAndCells, plus a blank token and a second page.
    func testTextLayoutGroupsWordsIntoLinesAndCells() {
        let h = 0.012
        let tokens = [
            TextToken(text: "TESCO", page: 1, x0: 0.15, x1: 0.20, y: 0.300, height: h),
            TextToken(text: "05", page: 1, x0: 0.05, x1: 0.07, y: 0.301, height: h),
            TextToken(text: "Page 2", page: 2, x0: 0.10, x1: 0.20, y: 0.050, height: h),
            TextToken(text: "Jan", page: 1, x0: 0.075, x1: 0.10, y: 0.299, height: h),
            TextToken(text: "STORES", page: 1, x0: 0.205, x1: 0.26, y: 0.300, height: h),
            TextToken(text: " ", page: 1, x0: 0.50, x1: 0.51, y: 0.300, height: h),
            TextToken(text: "12.50", page: 1, x0: 0.75, x1: 0.80, y: 0.302, height: h),
            TextToken(text: "Next", page: 1, x0: 0.15, x1: 0.20, y: 0.330, height: h),
        ]
        let lines = TextLayout.lines(from: tokens)
        XCTAssertEqual(lines.count, 3)
        guard lines.count == 3 else { return }
        XCTAssertEqual(lines[0].cells.map(\.text), ["05 Jan", "TESCO STORES", "12.50"])
        XCTAssertEqual(lines[0].text, "05 Jan TESCO STORES 12.50")
        XCTAssertEqual(lines[0].cells[1].x0, 0.15, accuracy: 1e-9)
        XCTAssertEqual(lines[0].cells[1].x1, 0.26, accuracy: 1e-9)
        XCTAssertEqual(lines[0].cells[1].center, 0.205, accuracy: 1e-9)
        XCTAssertEqual(lines[1].text, "Next")
        XCTAssertEqual(lines[1].page, 1)
        XCTAssertEqual(lines[2].text, "Page 2")
        XCTAssertEqual(lines[2].page, 2)
    }

    func testLineHeightIsAverageOfTokenHeights() {
        let tokens = [
            TextToken(text: "SONY", page: 0, x0: 0.10, x1: 0.18, y: 0.500, height: 0.010),
            TextToken(text: "WH-1000XM5", page: 0, x0: 0.19, x1: 0.40, y: 0.501, height: 0.014),
            TextToken(text: "249.00", page: 0, x0: 0.80, x1: 0.92, y: 0.499, height: 0.012),
            TextToken(text: "TOTAL", page: 0, x0: 0.10, x1: 0.20, y: 0.600, height: 0.030),
        ]
        let lines = TextLayout.lines(from: tokens)
        XCTAssertEqual(lines.count, 2)
        guard lines.count == 2 else { return }
        XCTAssertEqual(lines[0].cells.map(\.text), ["SONY WH-1000XM5", "249.00"])
        XCTAssertEqual(lines[0].height, 0.012, accuracy: 1e-9)
        XCTAssertEqual(lines[0].y, 0.500, accuracy: 1e-9)
        XCTAssertEqual(lines[1].height, 0.030, accuracy: 1e-9)

        // Lines built without a height (LocalLedger's initialiser) still compile, with height 0.
        XCTAssertEqual(TextLine(page: 1, y: 0.1, cells: []).height, 0)
    }

    func testReceiptTextSplitsCells() {
        let lines = ReceiptText.lines(from: "TOTAL      £249.00\nSony WH-1000XM5 249.00\n\n   \nMilk\t1.20")
        XCTAssertEqual(lines.count, 3)
        guard lines.count == 3 else { return }
        XCTAssertEqual(lines[0].cells.map(\.text), ["TOTAL", "£249.00"])
        XCTAssertEqual(lines[0].cells[0].x0, 0, accuracy: 1e-9)
        XCTAssertEqual(lines[0].cells[0].x1, 5.0 / 48, accuracy: 1e-9)
        XCTAssertEqual(lines[0].cells[1].x0, 11.0 / 48, accuracy: 1e-9)
        XCTAssertEqual(lines[0].cells[1].x1, 18.0 / 48, accuracy: 1e-9)
        XCTAssertEqual(lines[1].cells.map(\.text), ["Sony WH-1000XM5 249.00"])
        XCTAssertEqual(lines[2].cells.map(\.text), ["Milk", "1.20"])
        XCTAssertEqual(lines.map(\.page), [0, 0, 0])
        XCTAssertEqual(lines[1].y, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(lines[2].height, 0.02, accuracy: 1e-9)

        // Plain text keeps the cells apart, so it reads back the same.
        let stored = ReceiptText.plainText([
            line(0.1, [("TOTAL", 0.0, 0.1), ("£249.00", 0.8, 0.95)]),
            line(0.2, [("Thank you", 0.3, 0.5)]),
        ])
        XCTAssertEqual(stored, "TOTAL  £249.00\nThank you")
        XCTAssertEqual(ReceiptText.lines(from: stored).map { $0.cells.map(\.text) }, [["TOTAL", "£249.00"], ["Thank you"]])
    }

    func testFold() {
        XCTAssertEqual(TextFold.fold("Müller Crème STRASSE Straße"), "muller creme strasse strasse")
        XCTAssertEqual(TextFold.umlautVariant("Müller"), "mueller")
        XCTAssertEqual(TextFold.umlautVariant("Österreich Zürich"), "oesterreich zuerich")
        XCTAssertEqual(TextFold.fold("  Ça   va\u{00A0}bien "), "ca va bien")
        XCTAssertEqual(TextFold.fold("Sainsbury’s"), "sainsbury's")
        XCTAssertEqual(TextFold.fold("Œuvre"), "oeuvre")
        XCTAssertEqual(TextFold.words("Rechnung-Nr. 12/34: Müller"), ["rechnung", "nr", "12", "34", "muller"])
    }

    func testContainsWord() {
        XCTAssertFalse(TextFold.containsWord(TextFold.fold("Cooper Street"), "coop"))
        XCTAssertTrue(TextFold.containsWord(TextFold.fold("TESCO STORES 3297"), "tesco"))
        XCTAssertTrue(TextFold.containsWord("coop-city bern", "coop"))
        XCTAssertTrue(TextFold.containsWord("total to pay 12.50", "total to pay"))
        XCTAssertFalse(TextFold.containsWord("subtotal 5.00", "total"))
        XCTAssertTrue(TextFold.containsWord("subtotal 5.00 total 7.00", "total"))
        XCTAssertFalse(TextFold.containsWord("tesco", ""))
    }

    // MARK: - Lexicon

    /// Keyword lists are matched against folded text, so every entry must already be folded.
    func testLexiconEntriesArePreFolded() {
        let lists: [[String]] = [
            Lexicon.totalStrong, Lexicon.totalNormal, Lexicon.totalExcluded, Lexicon.paymentWords,
            Lexicon.changeWords, Lexicon.vatWords, Lexicon.purchaseDateLabels, Lexicon.deliveryDateLabels,
            Lexicon.negativeDateLabels, Lexicon.contractWords, Lexicon.warrantyWords, Lexicon.invoiceWords,
            Lexicon.onlineWords, Lexicon.documentWords, Lexicon.legalSuffixes,
        ]
        for list in lists {
            XCTAssertFalse(list.isEmpty)
            for entry in list {
                XCTAssertFalse(entry.isEmpty)
                XCTAssertEqual(entry, TextFold.fold(entry), "not folded: \(entry)")
            }
        }
        for merchant in Lexicon.knownMerchants {
            XCTAssertEqual(merchant.key, TextFold.fold(merchant.key), "not folded: \(merchant.key)")
            XCTAssertFalse(merchant.name.isEmpty, merchant.key)
        }
    }

    func testMerchantKeysUnique() {
        let keys = Lexicon.knownMerchants.map { $0.key }
        XCTAssertGreaterThanOrEqual(keys.count, 60)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(Lexicon.knownMerchants.first(where: { $0.key == "tesco" })?.category, ProductCategory.groceries)
        XCTAssertEqual(Lexicon.knownMerchants.first(where: { $0.key == "currys" })?.category, ProductCategory.electronics)
        XCTAssertEqual(Lexicon.knownMerchants.first(where: { $0.key == "coop" })?.category, ProductCategory.groceries)
    }

    func testLexiconTables() {
        for area in Lexicon.scottishPostcodeAreas {
            XCTAssertEqual(area, area.uppercased())
            XCTAssertTrue((1...2).contains(area.count), area)
        }
        XCTAssertEqual(Set(Lexicon.scottishPostcodeAreas).count, Lexicon.scottishPostcodeAreas.count)
        let rates = Lexicon.knownVATRatesPermille
        XCTAssertEqual(Set(rates).count, rates.count)
        XCTAssertTrue(rates.contains(200))
        XCTAssertTrue(rates.contains(81))
        XCTAssertEqual(Array(rates.prefix(4)).map { Money.percent(permille: $0) }, ["20", "5", "8.1", "2.6"])
    }
}
