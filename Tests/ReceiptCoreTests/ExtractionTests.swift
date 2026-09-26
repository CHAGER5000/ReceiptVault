import XCTest
@testable import ReceiptCore

/// TermsFinder and ReceiptExtractor on anonymised en/de/fr/it fixtures: till
/// receipts, invoices, a warranty card and a Swiss insurance policy, read
/// through ReceiptText.lines, plus positioned words for the tallest-line
/// merchant rule. These are heuristics, tuned over time: CI runs them but does
/// not block on them. Fixed dates only (never Date() for today).
final class ExtractionTests: XCTestCase {
    private let today = DayDate(year: 2026, month: 9, day: 25)

    /// A plain-text fixture read as a document (two or more spaces separate cells).
    private func fields(_ text: String, ocr: Bool = false) -> ReceiptFields {
        ReceiptExtractor.extract(text: text, today: today, fromOCR: ocr)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> DayDate {
        DayDate(year: y, month: m, day: d)
    }

    /// Words on one line of page 0, all `height` tall: each is (text, left, right).
    private func tokens(_ y: Double, _ height: Double, _ words: [(String, Double, Double)]) -> [TextToken] {
        words.map { TextToken(text: $0.0, page: 0, x0: $0.1, x1: $0.2, y: y, height: height) }
    }

    // MARK: - TermsFinder

    func testWarrantyMonths() {
        XCTAssertEqual(TermsFinder.warrantyMonths("2 years warranty"), 24)
        XCTAssertEqual(TermsFinder.warrantyMonths("1 year manufacturer's warranty"), 12)
        XCTAssertEqual(TermsFinder.warrantyMonths("garantie: 24 monate"), 24)
        XCTAssertEqual(TermsFinder.warrantyMonths("zwei jahre herstellergarantie"), 24)
        XCTAssertEqual(TermsFinder.warrantyMonths("garantie de deux ans"), 24)
        XCTAssertEqual(TermsFinder.warrantyMonths("3-year guarantee"), 36)
        XCTAssertEqual(TermsFinder.warrantyMonths("garanzia 2 anni"), 24)
        // Days count from 30.
        XCTAssertEqual(TermsFinder.warrantyMonths("90 days warranty"), 3)
        // find(in:) folds printed text first.
        XCTAssertEqual(TermsFinder.find(in: "2 Jahre Garantie").warrantyMonths, 24)
        XCTAssertEqual(TermsFinder.find(in: "Zwei Jahre Herstellergarantie").warrantyMonths, 24)
    }

    func testReturnDays() {
        XCTAssertEqual(TermsFinder.returnDays("returns within 28 days"), 28)
        XCTAssertEqual(TermsFinder.returnDays("umtausch/ruckgabe innerhalb von 30 tagen"), 30)
        XCTAssertEqual(TermsFinder.returnDays("retour/echange sous 30 jours"), 30)
        XCTAssertEqual(TermsFinder.returnDays("reso entro 14 giorni"), 14)
        let terms = TermsFinder.find(in: "Umtausch innerhalb von 30 Tagen nur mit Kassenbon")
        XCTAssertEqual(terms.returnDays, 30)
        XCTAssertNil(terms.warrantyMonths)
    }

    func testNoticePeriods() {
        XCTAssertEqual(TermsFinder.notice("kundigungsfrist 3 monate"), NoticePeriod(value: 3, unit: .months))
        XCTAssertEqual(TermsFinder.notice("notice period of 30 days"), NoticePeriod(value: 30, unit: .days))
        XCTAssertEqual(TermsFinder.notice("30 days' notice"), NoticePeriod(value: 30, unit: .days))
        XCTAssertEqual(TermsFinder.notice("preavis de 3 mois"), NoticePeriod(value: 3, unit: .months))
        XCTAssertEqual(TermsFinder.notice("delai de resiliation de 3 mois"), NoticePeriod(value: 3, unit: .months))
        XCTAssertEqual(TermsFinder.notice("frist von drei monaten"), NoticePeriod(value: 3, unit: .months))
        XCTAssertEqual(TermsFinder.notice("kundigungsfrist 6 wochen"), NoticePeriod(value: 6, unit: .weeks))
        XCTAssertEqual(TermsFinder.find(in: "Kündigungsfrist: 3 Monate zum Monatsende").notice,
                       NoticePeriod(value: 3, unit: .months))
    }

    func testContractTermAndRenewal() {
        let span = TermsFinder.term("Vertragsdauer 01.01.2025 \u{2013} 31.12.2025")
        XCTAssertEqual(span.start, day(2025, 1, 1))
        XCTAssertEqual(span.end, day(2025, 12, 31))

        // One date after an end label.
        XCTAssertEqual(TermsFinder.term("Gültig bis 31.03.2026").end, day(2026, 3, 31))
        XCTAssertNil(TermsFinder.term("Gültig bis 31.03.2026").start)
        // A start date with a printed length gives the end too.
        let fromLength = TermsFinder.term("Laufzeit: 12 Monate ab 01.04.2025")
        XCTAssertEqual(fromLength.start, day(2025, 4, 1))
        XCTAssertEqual(fromLength.end, day(2026, 3, 31))

        XCTAssertEqual(TermsFinder.renewal("verlangert sich stillschweigend um ein weiteres jahr")?.autoRenews, true)
        XCTAssertEqual(TermsFinder.renewal("verlangert sich stillschweigend um ein weiteres jahr")?.months, 12)
        XCTAssertEqual(TermsFinder.renewal("reconduction tacite")?.autoRenews, true)
        XCTAssertNil(TermsFinder.renewal("reconduction tacite")?.months)
        XCTAssertEqual(TermsFinder.renewal("rinnovo tacito")?.autoRenews, true)
        XCTAssertEqual(TermsFinder.renewal("renews automatically")?.autoRenews, true)
        // Negated or ending statements say it does not renew.
        XCTAssertEqual(TermsFinder.renewal("keine automatische verlangerung")?.autoRenews, false)
        XCTAssertEqual(TermsFinder.renewal("der vertrag endet automatisch")?.autoRenews, false)
        XCTAssertNil(TermsFinder.renewal("zwei jahre garantie"))

        let terms = TermsFinder.find(in: "Der Vertrag verlängert sich stillschweigend um ein weiteres Jahr.")
        XCTAssertEqual(terms.autoRenews, true)
        XCTAssertEqual(terms.renewalMonths, 12)
    }

    func testNoFalsePositives() {
        XCTAssertNil(TermsFinder.warrantyMonths("2 jahre alt"))
        XCTAssertNil(TermsFinder.warrantyMonths("bergkase 2 jahre alt, mit garantie"))
        XCTAssertNil(TermsFinder.warrantyMonths("garantiert frisch"))
        XCTAssertNil(TermsFinder.warrantyMonths("frische-garantie 30 tage"))
        XCTAssertNil(TermsFinder.warrantyMonths("30-day money back guarantee"))
        XCTAssertNil(TermsFinder.warrantyMonths("30 days"))
        XCTAssertNil(TermsFinder.returnDays("30 days"))
        XCTAssertNil(TermsFinder.notice("30 days"))
        XCTAssertNil(TermsFinder.notice("zahlbar innerhalb von 30 tagen"))
        XCTAssertEqual(TermsFinder.find(in: "30 days"), PrintedTerms())
        XCTAssertEqual(TermsFinder.find(in: "Sony WH-1000XM5  249.00\nTOTAL  249.00"), PrintedTerms())
        XCTAssertEqual(TermsFinder.find(in: ""), PrintedTerms())
    }

    // MARK: - Whole documents

    func testUKTillReceipt() {
        let f = fields("""
            CURRYS
            Oxford Street, London W1C 1AB
            VAT No: GB 123 4567 89
            12/03/2024  14:32
            Sony WH-1000XM5        £249.00
            TOTAL                  £249.00
            VISA DEBIT             £249.00
            VAT 20%                 £41.50
            Thank you for shopping at Currys
            """)
        XCTAssertEqual(f.merchant?.value, "Currys")
        XCTAssertEqual(f.date?.value, day(2024, 3, 12))
        XCTAssertEqual(f.total?.value, 24900)
        XCTAssertEqual(f.currency?.value, "GBP")
        XCTAssertEqual(f.vat?.value, 4150)
        XCTAssertEqual(f.vatRatePermille?.value, 200)
        XCTAssertFalse(f.vatIsCalculated)
        XCTAssertEqual(f.items.map(\.name), ["Sony WH-1000XM5"])
        XCTAssertEqual(f.suggestedTitle, "Sony WH-1000XM5")
        XCTAssertEqual(f.channel?.value, PurchaseChannel.store)
        XCTAssertEqual(f.jurisdiction?.value, Jurisdiction.englandWales)
        XCTAssertEqual(f.category?.value, ProductCategory.electronics)
        XCTAssertEqual(f.kind.value, ItemKind.receipt)
        XCTAssertFalse(f.needsReview)
        XCTAssertTrue(f.checkFields.isEmpty)
    }

    func testSwissMigrosTwoVATRates() {
        let f = fields("""
            MIGROS
            Genossenschaft Migros Zürich
            Vollmilch            1.95 A
            Ruchbrot             3.40 A
            Batterien AA        12.90 B
            TOTAL CHF           18.25
            TWINT               18.25
            MWST%   Brutto   MWST
            2.6       5.35   0.14
            8.1      12.90   0.97
            14.01.2025  18:04
            """)
        XCTAssertEqual(f.merchant?.value, "Migros")
        XCTAssertEqual(f.total?.value, 1825)
        XCTAssertEqual(f.currency?.value, "CHF")
        // 0.14 at 2.6 % plus 0.97 at 8.1 %; no single rate.
        XCTAssertEqual(f.vat?.value, 111)
        XCTAssertNil(f.vatRatePermille)
        XCTAssertEqual(f.jurisdiction?.value, Jurisdiction.switzerland)
        XCTAssertEqual(f.category?.value, ProductCategory.groceries)
        XCTAssertEqual(f.date?.value, day(2025, 1, 14))
    }

    func testSwissWholeFrancDash() {
        let f = fields("""
            Velo Huber
            Veloservice          120.\u{2013}
            Total Fr.            120.\u{2013}
            Bar                  120.\u{2013}
            """)
        XCTAssertEqual(f.total?.value, 12000)
        XCTAssertEqual(f.currency?.value, "CHF")
        XCTAssertEqual(ReceiptExtractor.fill(FillField.total, fromLine: "Total Fr. 12.-", fromOCR: false),
                       FillValue.amount(minor: 1200, currency: "CHF"))
    }

    func testGermanInvoice() {
        let f = fields("""
            Elektro Schneider GmbH
            Hauptstraße 5, 10115 Berlin
            Rechnung
            Rechnungsnummer: RE-2025-0042
            Bestellnummer: 88812
            Rechnungsdatum: 05.02.2025
            Lieferdatum: 07.02.2025
            Fälligkeitsdatum: 19.02.2025
            Pos  Artikel  Menge  Preis
            1  Kaffeevollautomat  1  1.234,50 €
            Nettobetrag  1.037,39 €
            MwSt. 19 %  197,11 €
            Gesamtbetrag  1.234,50 €
            """)
        XCTAssertEqual(f.date?.value, day(2025, 2, 5))
        XCTAssertEqual(f.deliveryDate?.value, day(2025, 2, 7))
        XCTAssertEqual(f.total?.value, 123450)
        XCTAssertEqual(f.currency?.value, "EUR")
        XCTAssertEqual(f.vat?.value, 19711)
        XCTAssertEqual(f.vatRatePermille?.value, 190)
        XCTAssertEqual(f.kind.value, ItemKind.invoice)
        XCTAssertEqual(f.channel?.value, PurchaseChannel.online)
        XCTAssertEqual(f.jurisdiction?.value, Jurisdiction.eu)
        XCTAssertEqual(f.merchant?.value, "Elektro Schneider")
        XCTAssertEqual(f.items.map(\.name), ["Kaffeevollautomat"])
    }

    func testFrenchTicket() {
        let f = fields("""
            FNAC
            26-30 avenue des Ternes
            75017 Paris
            Casque Bluetooth  89,99 €
            Total HT  74,99 €
            TVA 20%  15,00 €
            TOTAL TTC  89,99 €
            CB  89,99 €
            Le 14/06/2025 à 15h42
            """)
        XCTAssertEqual(f.total?.value, 8999)
        XCTAssertEqual(f.currency?.value, "EUR")
        XCTAssertEqual(f.vat?.value, 1500)
        XCTAssertEqual(f.vatRatePermille?.value, 200)
        XCTAssertEqual(f.date?.value, day(2025, 6, 14))
        XCTAssertEqual(f.merchant?.value, "Fnac")
        XCTAssertEqual(f.jurisdiction?.value, Jurisdiction.eu)
    }

    func testWarrantyCard() {
        let f = fields("""
            GARANTIEKARTE
            Modell: Kaffeevollautomat EA-8150
            Seriennummer: 4711-0815
            Kaufdatum: 14.03.2025
            Händler: Fust AG, Bern
            2 Jahre Herstellergarantie ab Kaufdatum
            """)
        XCTAssertEqual(f.kind.value, ItemKind.warranty)
        XCTAssertEqual(f.merchant?.value, "Fust")
        XCTAssertEqual(f.category?.value, ProductCategory.appliance)
        XCTAssertEqual(f.date?.value, day(2025, 3, 14))
        XCTAssertEqual(f.terms.warrantyMonths, 24)
        XCTAssertNil(f.total)
    }

    func testSwissInsurancePolicy() {
        let f = fields("""
            Helvetia Versicherungen
            Police Nr. 12.345.678
            Hausratversicherung
            Versicherungsdauer: 01.01.2025 \u{2013} 31.12.2025
            Kündigungsfrist: 3 Monate
            Der Vertrag verlängert sich stillschweigend um ein weiteres Jahr, wenn er nicht bis 3 Monate vor Ablauf gekündigt wird.
            Jahresprämie CHF 384.60
            """)
        XCTAssertEqual(f.kind.value, ItemKind.contract)
        XCTAssertEqual(f.terms.termStart, day(2025, 1, 1))
        XCTAssertEqual(f.terms.termEnd, day(2025, 12, 31))
        XCTAssertEqual(f.terms.notice, NoticePeriod(value: 3, unit: .months))
        XCTAssertEqual(f.terms.autoRenews, true)
        XCTAssertEqual(f.terms.renewalMonths, 12)
        XCTAssertEqual(f.currency?.value, "CHF")
        XCTAssertEqual(f.jurisdiction?.value, Jurisdiction.switzerland)
    }

    // MARK: - Total

    func testSubtotalDiscountCashChange() {
        let f = fields("""
            CORNER SHOP
            Milk  1.20
            Bread  2.50
            Coffee  4.20
            SUBTOTAL  7.90
            DISCOUNT  -0.50
            TOTAL  7.40
            CASH  10.00
            CHANGE  2.60
            """)
        XCTAssertEqual(f.total?.value, 740)
        XCTAssertGreaterThanOrEqual(f.total?.confidence ?? 0, 0.9)
        XCTAssertNil(f.totalSuggestion)
        XCTAssertEqual(f.items.map(\.name), ["Milk", "Bread", "Coffee"])
    }

    func testTotalAmountOnNextLine() {
        let f = fields("""
            Garden Centre
            Rose bush  12.99
            Compost  5.00
            Amount due
            £17.99
            Card  £17.99
            """)
        XCTAssertEqual(f.total?.value, 1799)
        XCTAssertEqual(f.total?.line, 4)
        XCTAssertEqual(f.currency?.value, "GBP")

        let german = fields("Blumen Meier\nZu bezahlen\nCHF 45.60")
        XCTAssertEqual(german.total?.value, 4560)
        XCTAssertEqual(german.currency?.value, "CHF")
    }

    func testPaymentLineCorroborates() {
        let f = fields("""
            Books and Maps
            Novel  8.99
            Map  4.50
            TOTAL  13.49
            MASTERCARD  13.49
            """)
        XCTAssertEqual(f.total?.value, 1349)
        XCTAssertGreaterThanOrEqual(f.total?.confidence ?? 0, 0.9)

        // The label alone is less sure, but still fills the form.
        let plain = fields("Books and Maps\nNovel  8.99\nMap  4.50\nTOTAL  13.49")
        XCTAssertEqual(plain.total?.value, 1349)
        XCTAssertLessThan(plain.total?.confidence ?? 1, 0.9)
        XCTAssertTrue(plain.total?.shouldFill ?? false)

        // No label: the card payment is the total, marked 'Please check'.
        let card = fields("Books and Maps\nNovel  8.99\nMap  4.50\nVISA CONTACTLESS  13.49")
        XCTAssertEqual(card.total?.value, 1349)
        XCTAssertEqual(card.total?.confidence ?? 0, 0.6, accuracy: 0.001)
        XCTAssertTrue(card.checkFields.contains(FillField.total))
    }

    func testFallbackLargestIsSuggestionOnly() {
        let text = """
            Market Stall
            Apples  2.40
            Cheese  6.80
            Honey  5.50
            Cash  20.00
            Change  5.30
            """
        let f = fields(text)
        XCTAssertNil(f.total)
        // Cash handed over and change are never offered.
        XCTAssertEqual(f.totalSuggestion, 680)
        XCTAssertTrue(f.needsReview)

        let direct = ReceiptExtractor.findTotal(ReceiptText.lines(from: text), fromOCR: false)
        XCTAssertNil(direct.total)
        XCTAssertEqual(direct.suggestion, 680)
    }

    func testOCRSlipTotal() {
        let text = "KIOSK\nNewspaper  2.50\nChocolate  8.00\nTOTAL  1O.5O"
        XCTAssertEqual(fields(text, ocr: true).total?.value, 1050)
        // Typed text is never "corrected".
        XCTAssertNil(fields(text).total)
    }

    func testVATCalculatedFromPrintedRate() {
        let f = fields("""
            Corner Café
            Flat white  £3.20
            Croissant  £2.80
            Total  £6.00
            Prices include VAT at 20%
            """)
        XCTAssertEqual(f.total?.value, 600)
        XCTAssertEqual(f.vat?.value, 100)
        XCTAssertEqual(f.vatRatePermille?.value, 200)
        XCTAssertTrue(f.vatIsCalculated)
        XCTAssertTrue(f.checkFields.contains(FillField.vat))
    }

    // MARK: - Currency and jurisdiction

    func testCurrencyFromSwissUID() {
        let f = fields("""
            Schreinerei Holz
            CHE-123.456.789 MWST
            Reparatur Stuhl  85.00
            Total  85.00
            """)
        XCTAssertEqual(f.total?.value, 8500)
        XCTAssertEqual(f.currency?.value, "CHF")
        XCTAssertTrue(f.currency?.needsCheck ?? false)
        XCTAssertEqual(f.jurisdiction?.value, Jurisdiction.switzerland)

        let uk = fields("Joe's Cafe\nVAT Reg No GB 123 4567 89\nTea  2.20\nTotal  2.20")
        XCTAssertEqual(uk.currency?.value, "GBP")
    }

    func testScottishPostcode() {
        let f = fields("""
            Edinburgh Books
            12 Princes Street
            Edinburgh EH1 1YZ
            Atlas  £30.00
            TOTAL  £30.00
            """)
        XCTAssertEqual(f.currency?.value, "GBP")
        XCTAssertEqual(f.jurisdiction?.value, Jurisdiction.scotland)

        XCTAssertEqual(ReceiptExtractor.guessJurisdiction("London SW1A 1AA", currency: "GBP")?.value,
                       Jurisdiction.englandWales)
        XCTAssertEqual(ReceiptExtractor.guessJurisdiction("Glasgow G2 3AB", currency: nil)?.value,
                       Jurisdiction.scotland)
        XCTAssertEqual(ReceiptExtractor.guessJurisdiction("Edinburgh EH1 1YZ", currency: "CHF")?.value,
                       Jurisdiction.switzerland)
        XCTAssertNil(ReceiptExtractor.guessJurisdiction("Paris", currency: nil))
    }

    // MARK: - Dates

    func testFutureDatesIgnored() {
        // Today is 2026-09-25: tomorrow is allowed, the day after is not.
        XCTAssertNil(fields("Kiosk\nDatum: 27.09.2026\nTotal  5.00").date)
        XCTAssertEqual(fields("Kiosk\nDatum: 26.09.2026\nTotal  5.00").date?.value, day(2026, 9, 26))
        // More than 15 years old.
        XCTAssertNil(fields("Kiosk\nDatum: 01.01.2010\nTotal  5.00").date)
        XCTAssertEqual(fields("Kiosk\n14.08.2027\nDatum: 20.09.2026\nTotal  5.00").date?.value, day(2026, 9, 20))
    }

    // MARK: - Merchant

    func testMerchantSkipsNoise() {
        let f = fields("""
            TAX INVOICE
            Bäckerei Müller AG
            Bahnhofstrasse 5
            8001 Zürich
            Tel 044 123 45 67
            Gipfeli  2 x 1.80  3.60
            Total CHF  3.60
            """)
        XCTAssertEqual(f.merchant?.value, "Bäckerei Müller")
        XCTAssertTrue(f.merchant?.needsCheck ?? false)

        // ALL CAPS becomes title case.
        let caps = ReceiptExtractor.findMerchant(ReceiptText.lines(from: "BÄCKEREI MÜLLER AG\nBahnhofstrasse 5\n8001 Zürich"))
        XCTAssertEqual(caps?.value, "Bäckerei Müller")
    }

    func testKnownMerchantInFooter() {
        let f = fields("""
            Oxford Street
            Receipt
            Duvet cover  45.00
            TOTAL  45.00
            VISA  45.00
            Thank you for shopping with us
            www.johnlewis.com
            """)
        XCTAssertEqual(f.merchant?.value, "John Lewis")
        XCTAssertGreaterThanOrEqual(f.merchant?.confidence ?? 0, 0.9)
        XCTAssertEqual(f.category?.value, ProductCategory.otherGoods)

        // No name line at the top: the web domain, marked 'Please check'.
        let domain = ReceiptExtractor.findMerchant(ReceiptText.lines(from: """
            Receipt
            12.03.2025
            Service  80.00
            Total  80.00
            www.velo-huber.ch
            """))
        XCTAssertEqual(domain?.value, "Velo Huber")
        XCTAssertEqual(domain?.confidence ?? 0, 0.55, accuracy: 0.001)
    }

    /// Positioned words: the tallest name-like line near the top wins, even
    /// below a smaller one.
    func testTallestEarlyLineIsMerchant() {
        func bakery(nameHeight: Double) -> [TextLine] {
            let rows: [[TextToken]] = [
                tokens(0.03, 0.012, [("Fresh", 0.30, 0.42), ("Bakery", 0.425, 0.58)]),
                tokens(0.08, nameHeight, [("Rosie's", 0.20, 0.48), ("Kitchen", 0.50, 0.80)]),
                tokens(0.30, 0.012, [("Cappuccino", 0.05, 0.30), ("3.20", 0.85, 0.95)]),
                tokens(0.40, 0.012, [("TOTAL", 0.05, 0.20), ("3.20", 0.85, 0.95)]),
            ]
            return TextLayout.lines(from: rows.flatMap { $0 })
        }
        let tall = ReceiptExtractor.findMerchant(bakery(nameHeight: 0.035))
        XCTAssertEqual(tall?.value, "Rosie's Kitchen")
        XCTAssertEqual(tall?.confidence ?? 0, 0.6, accuracy: 0.001)
        // With equal heights the first name-like line wins.
        XCTAssertEqual(ReceiptExtractor.findMerchant(bakery(nameHeight: 0.012))?.value, "Fresh Bakery")
    }

    /// A taller heading, a taller address and a taller line far down the page
    /// are all passed over; the legal suffix goes and ALL CAPS become title case.
    func testTallestLineSkipsHeadingsAndLateLines() {
        let rows: [[TextToken]] = [
            tokens(0.03, 0.040, [("RECEIPT", 0.35, 0.65)]),
            tokens(0.09, 0.030, [("MEYER", 0.20, 0.38), ("&", 0.39, 0.41), ("CO.", 0.42, 0.50), ("KG", 0.51, 0.58)]),
            tokens(0.13, 0.030, [("Hauptstrasse", 0.20, 0.50), ("12", 0.51, 0.55)]),
            tokens(0.30, 0.012, [("Coffee", 0.05, 0.15), ("beans", 0.16, 0.25), ("12.90", 0.85, 0.95)]),
            tokens(0.40, 0.012, [("TOTAL", 0.05, 0.20), ("12.90", 0.85, 0.95)]),
            tokens(0.85, 0.050, [("SUMMER", 0.20, 0.50), ("SALE", 0.52, 0.70)]),
        ]
        let lines = TextLayout.lines(from: rows.flatMap { $0 })
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(ReceiptExtractor.findMerchant(lines)?.value, "Meyer")
    }

    // MARK: - Items

    func testItemsStripQuantities() {
        let f = fields("""
            TECH STORE
            2 x USB-C CABLE 123456 19.98 A
            HDMI ADAPTER  8.99 A
            AA BATTERY 3 @ 1.50  4.50
            TOTAL  33.47
            """)
        XCTAssertEqual(f.items, [
            ItemLine(name: "USB-C CABLE", quantity: 2, amountMinor: 1998),
            ItemLine(name: "HDMI ADAPTER", quantity: 1, amountMinor: 899),
            ItemLine(name: "AA BATTERY", quantity: 3, amountMinor: 450),
        ])
        XCTAssertEqual(f.suggestedTitle, "USB-C CABLE")

        // At most 30 lines.
        let many = (1...40).map { "Item \($0)  1.00" }.joined(separator: "\n") + "\nTOTAL  40.00"
        XCTAssertEqual(fields(many).items.count, 30)
    }

    // MARK: - Guesses

    func testKindGuesses() {
        XCTAssertEqual(ReceiptExtractor.guessKind(TextFold.fold("Warranty Card\nModel: KX-200")).value, ItemKind.warranty)
        XCTAssertEqual(ReceiptExtractor.guessKind(TextFold.fold("Versicherungspolice\nHausrat")).value, ItemKind.contract)
        XCTAssertEqual(ReceiptExtractor.guessKind(TextFold.fold("Mietvertrag")).value, ItemKind.contract)
        XCTAssertEqual(ReceiptExtractor.guessKind(TextFold.fold("FACTURE N° 2025-118")).value, ItemKind.invoice)
        XCTAssertEqual(ReceiptExtractor.guessKind(TextFold.fold("Kassenbon\nMilch 1.20")).value, ItemKind.receipt)
        let blank = ReceiptExtractor.guessKind("")
        XCTAssertEqual(blank.value, ItemKind.receipt)
        XCTAssertFalse(blank.shouldFill)

        // A receipt that prints automatic renewal is a contract.
        let gym = fields("Gym membership\nRenews automatically each month\nTotal  £29.99")
        XCTAssertEqual(gym.kind.value, ItemKind.contract)
        XCTAssertEqual(gym.terms.autoRenews, true)
        XCTAssertEqual(gym.terms.renewalMonths, 1)
    }

    // MARK: - Pick from document

    func testFillFromLine() {
        XCTAssertEqual(ReceiptExtractor.fill(FillField.total, fromLine: "TOTAL 45.60", fromOCR: false),
                       FillValue.amount(minor: 4560, currency: nil))
        XCTAssertEqual(ReceiptExtractor.fill(FillField.date, fromLine: "Kaufdatum 3. März 2025", fromOCR: false),
                       FillValue.day(day(2025, 3, 3)))
        XCTAssertEqual(ReceiptExtractor.fill(FillField.deliveryDate, fromLine: "Lieferdatum: 07.02.2025", fromOCR: false),
                       FillValue.day(day(2025, 2, 7)))
        XCTAssertEqual(ReceiptExtractor.fill(FillField.vat, fromLine: "MwSt 8.1%  3.45", fromOCR: false),
                       FillValue.amount(minor: 345, currency: nil))
        XCTAssertEqual(ReceiptExtractor.fill(FillField.total, fromLine: "Refund  -12.50", fromOCR: false),
                       FillValue.amount(minor: 1250, currency: nil))
        XCTAssertEqual(ReceiptExtractor.fill(FillField.total, fromLine: "TOTAL 1O.5O", fromOCR: true),
                       FillValue.amount(minor: 1050, currency: nil))
        XCTAssertEqual(ReceiptExtractor.fill(FillField.merchant, fromLine: "  Bäckerei Müller  ", fromOCR: false),
                       FillValue.text("Bäckerei Müller"))
        XCTAssertNil(ReceiptExtractor.fill(FillField.notes, fromLine: "   ", fromOCR: false))
        XCTAssertNil(ReceiptExtractor.fill(FillField.total, fromLine: "Thank you", fromOCR: false))
        XCTAssertNil(ReceiptExtractor.fill(FillField.date, fromLine: "Thank you", fromOCR: false))
    }

    // MARK: - Robustness

    func testEmptyAndGarbageDoNotCrash() {
        XCTAssertEqual(fields(""), ReceiptFields())
        XCTAssertTrue(fields("").needsReview)
        XCTAssertTrue(fields("   \n\n\t").needsReview)
        XCTAssertTrue(ReceiptExtractor.extract(lines: [], today: today, fromOCR: true).needsReview)

        let garbage = [
            "%%%% ::: ///\n12:30 99%\n-- -- --",
            "\u{1F9FE}\u{1F9FE}\u{1F9FE}\n€€€ £££\nTOTAL",
            "TOTAL 99999999999999.99",
            String(repeating: "9", count: 5000),
        ]
        for text in garbage {
            let f = fields(text)
            XCTAssertTrue(f.needsReview, text)
            XCTAssertNil(f.total, text)
        }
        XCTAssertTrue(fields("||| lll OOO\nIl1 O0O", ocr: true).needsReview)

        XCTAssertNil(ReceiptExtractor.findMerchant([]))
        XCTAssertNil(ReceiptExtractor.findTotal([], fromOCR: false).total)
        XCTAssertNil(ReceiptExtractor.findCurrency([], totalLine: 3))
        XCTAssertNil(ReceiptExtractor.findVAT([], total: nil, fromOCR: false).amount)
        XCTAssertNil(ReceiptExtractor.findDates([], today: today).purchase)
        XCTAssertTrue(ReceiptExtractor.findItems([], before: 5, fromOCR: false).isEmpty)
        XCTAssertNil(ReceiptExtractor.guessChannel(""))
        XCTAssertNil(ReceiptExtractor.guessCategory(merchant: nil, folded: ""))
    }
}
