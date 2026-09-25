import Foundation

// The legal and shop-policy defaults behind every key date, as editable data.
// 0 always means 'does not apply'. Each value has a basis text and says
// whether it is law or an assumption; the planner turns them into dates.

// MARK: - Rules per jurisdiction

/// One jurisdiction's defaults. Days, months or years as the field names say;
/// 0 means the rule does not apply.
struct JurisdictionRules: Codable, Equatable {
    var returnDaysStore: Int
    var cancellationDaysOnline: Int
    var cancellationDaysDoorstep: Int
    var rightToRejectDays: Int
    var faultPresumptionMonths: Int
    var legalGuaranteeMonths: Int
    var usedGoodsGuaranteeMonths: Int
    var claimLimitYears: Int
    var manufacturerWarrantyMonths: Int

    func value(_ f: RuleField) -> Int {
        switch f {
        case .returnDaysStore: return returnDaysStore
        case .cancellationDaysOnline: return cancellationDaysOnline
        case .cancellationDaysDoorstep: return cancellationDaysDoorstep
        case .rightToRejectDays: return rightToRejectDays
        case .faultPresumptionMonths: return faultPresumptionMonths
        case .legalGuaranteeMonths: return legalGuaranteeMonths
        case .usedGoodsGuaranteeMonths: return usedGoodsGuaranteeMonths
        case .claimLimitYears: return claimLimitYears
        case .manufacturerWarrantyMonths: return manufacturerWarrantyMonths
        }
    }

    mutating func set(_ f: RuleField, _ v: Int) {
        switch f {
        case .returnDaysStore: returnDaysStore = v
        case .cancellationDaysOnline: cancellationDaysOnline = v
        case .cancellationDaysDoorstep: cancellationDaysDoorstep = v
        case .rightToRejectDays: rightToRejectDays = v
        case .faultPresumptionMonths: faultPresumptionMonths = v
        case .legalGuaranteeMonths: legalGuaranteeMonths = v
        case .usedGoodsGuaranteeMonths: usedGoodsGuaranteeMonths = v
        case .claimLimitYears: claimLimitYears = v
        case .manufacturerWarrantyMonths: manufacturerWarrantyMonths = v
        }
    }

    /// The built-in defaults, in the order store return / online cancel /
    /// doorstep cancel / reject / fault presumption / legal guarantee /
    /// used-goods guarantee / claim limit / manufacturer warranty.
    static func standard(_ j: Jurisdiction) -> JurisdictionRules {
        switch j {
        case .englandWales:
            return JurisdictionRules(returnDaysStore: 28, cancellationDaysOnline: 14, cancellationDaysDoorstep: 14,
                                     rightToRejectDays: 30, faultPresumptionMonths: 6, legalGuaranteeMonths: 0,
                                     usedGoodsGuaranteeMonths: 0, claimLimitYears: 6, manufacturerWarrantyMonths: 12)
        case .scotland:
            var rules = JurisdictionRules.standard(.englandWales)
            rules.claimLimitYears = 5
            return rules
        case .switzerland:
            return JurisdictionRules(returnDaysStore: 14, cancellationDaysOnline: 0, cancellationDaysDoorstep: 14,
                                     rightToRejectDays: 0, faultPresumptionMonths: 0, legalGuaranteeMonths: 24,
                                     usedGoodsGuaranteeMonths: 12, claimLimitYears: 0, manufacturerWarrantyMonths: 0)
        case .eu:
            return JurisdictionRules(returnDaysStore: 14, cancellationDaysOnline: 14, cancellationDaysDoorstep: 14,
                                     rightToRejectDays: 0, faultPresumptionMonths: 12, legalGuaranteeMonths: 24,
                                     usedGoodsGuaranteeMonths: 12, claimLimitYears: 0, manufacturerWarrantyMonths: 12)
        }
    }
}

/// One editable value in JurisdictionRules, for the Rules editor.
enum RuleField: String, CaseIterable, Identifiable {
    case returnDaysStore, cancellationDaysOnline, cancellationDaysDoorstep, rightToRejectDays, faultPresumptionMonths
    case legalGuaranteeMonths, usedGoodsGuaranteeMonths, claimLimitYears, manufacturerWarrantyMonths

    var id: String { rawValue }

    var label: String {
        switch self {
        case .returnDaysStore: return "Shop return window"
        case .cancellationDaysOnline: return "Online cancellation"
        case .cancellationDaysDoorstep: return "Doorstep or phone cancellation"
        case .rightToRejectDays: return "Right to reject"
        case .faultPresumptionMonths: return "Fault presumption"
        case .legalGuaranteeMonths: return "Legal guarantee"
        case .usedGoodsGuaranteeMonths: return "Legal guarantee, used goods"
        case .claimLimitYears: return "Claim time limit"
        case .manufacturerWarrantyMonths: return "Manufacturer warranty"
        }
    }

    /// 'days', 'months' or 'years'.
    var unit: String {
        switch self {
        case .returnDaysStore, .cancellationDaysOnline, .cancellationDaysDoorstep, .rightToRejectDays:
            return "days"
        case .faultPresumptionMonths, .legalGuaranteeMonths, .usedGoodsGuaranteeMonths, .manufacturerWarrantyMonths:
            return "months"
        case .claimLimitYears:
            return "years"
        }
    }

    /// The top of the editor's stepper (the bottom is 0).
    var maxValue: Int {
        switch self {
        case .returnDaysStore: return 365
        case .cancellationDaysOnline, .cancellationDaysDoorstep, .rightToRejectDays: return 90
        case .faultPresumptionMonths: return 60
        case .legalGuaranteeMonths, .usedGoodsGuaranteeMonths: return 120
        case .claimLimitYears: return 30
        case .manufacturerWarrantyMonths: return 240
        }
    }
}

// MARK: - Basis texts

/// Where a default comes from, and whether it is an assumption rather than law.
struct RuleBasis: Equatable {
    var basis: String
    var isAssumption: Bool
}

enum RuleBases {
    static let shopPolicy = "Typical shop policy, not a legal right"
    static let manufacturerTypical = "Typical manufacturer warranty, not guaranteed"

    static func basis(_ f: RuleField, _ j: Jurisdiction) -> RuleBasis {
        switch j {
        case .englandWales, .scotland: return RuleBases.uk(f, scotland: j == .scotland)
        case .switzerland: return RuleBases.swiss(f)
        case .eu: return RuleBases.eu(f)
        }
    }

    private static func law(_ text: String) -> RuleBasis {
        RuleBasis(basis: text, isAssumption: false)
    }

    private static func assumed(_ text: String) -> RuleBasis {
        RuleBasis(basis: text, isAssumption: true)
    }

    private static func uk(_ f: RuleField, scotland: Bool) -> RuleBasis {
        switch f {
        case .returnDaysStore: return assumed(RuleBases.shopPolicy)
        case .cancellationDaysOnline: return law("Consumer Contracts Regulations 2013")
        case .cancellationDaysDoorstep: return law("Consumer Contracts Regulations 2013")
        case .rightToRejectDays: return law("Consumer Rights Act 2015, s.22")
        case .faultPresumptionMonths: return law("Consumer Rights Act 2015, s.19(14)–(15)")
        case .legalGuaranteeMonths: return law("No fixed guarantee period in UK law; faults can be claimed up to the claim time limit")
        case .usedGoodsGuaranteeMonths: return law("No separate period for used goods in UK law")
        case .claimLimitYears:
            return scotland
                ? assumed("Prescription and Limitation (Scotland) Act 1973; start date simplified")
                : law("Limitation Act 1980 s.5; Northern Ireland assumed the same")
        case .manufacturerWarrantyMonths: return assumed(RuleBases.manufacturerTypical)
        }
    }

    private static func swiss(_ f: RuleField) -> RuleBasis {
        switch f {
        case .returnDaysStore: return assumed(RuleBases.shopPolicy)
        case .cancellationDaysOnline: return law("No statutory right to cancel online purchases in Swiss law")
        case .cancellationDaysDoorstep: return assumed("OR Art. 40a–40f; start date assumed")
        case .rightToRejectDays: return law("No right to reject in Swiss law; see the legal guarantee")
        case .faultPresumptionMonths: return law("No fault presumption period in Swiss law")
        case .legalGuaranteeMonths: return law("OR Art. 210 (2 years since 2013); sellers may limit it in their terms (OR Art. 199)")
        case .usedGoodsGuaranteeMonths: return assumed("OR Art. 210 para. 4: 1 year for used goods, if agreed")
        case .claimLimitYears: return law("No separate claim limit; the guarantee period applies (OR Art. 210)")
        case .manufacturerWarrantyMonths: return assumed("No typical default; only a printed or entered warranty counts")
        }
    }

    private static func eu(_ f: RuleField) -> RuleBasis {
        switch f {
        case .returnDaysStore: return assumed(RuleBases.shopPolicy)
        case .cancellationDaysOnline: return law("Directive 2011/83/EU, Art. 9")
        case .cancellationDaysDoorstep: return law("Directive 2011/83/EU, Art. 9")
        case .rightToRejectDays: return law("No short-term right to reject in EU law; see the legal guarantee")
        case .faultPresumptionMonths: return assumed("Directive (EU) 2019/771 Art. 11, minimum; some countries 24 months")
        case .legalGuaranteeMonths: return law("Directive (EU) 2019/771 Art. 10, minimum")
        case .usedGoodsGuaranteeMonths: return assumed("Directive (EU) 2019/771 Art. 10(6): 1 year for used goods, if agreed")
        case .claimLimitYears: return law("Limitation periods are set by each country and are not planned")
        case .manufacturerWarrantyMonths: return assumed(RuleBases.manufacturerTypical)
        }
    }
}

// MARK: - Contract presets

/// Typical terms for a kind of contract. `fixedEndMonth`/`fixedEndDay` name a
/// date every term ends on (0 = none).
struct ContractPreset: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var renewalMonths: Int
    var autoRenews: Bool
    var notice: NoticePeriod
    var fixedEndMonth: Int
    var fixedEndDay: Int
    var note: String
    var isAssumption: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, renewalMonths, autoRenews, notice, fixedEndMonth, fixedEndDay, note, isAssumption
    }

    static let standard: [ContractPreset] = [
        ContractPreset(id: "chInsuranceVVG", name: "Swiss insurance (VVG)", renewalMonths: 12, autoRenews: true,
                       notice: NoticePeriod(value: 3, unit: .months), fixedEndMonth: 0, fixedEndDay: 0,
                       note: "Contracts running longer than 3 years can also be ended at the end of the third year, with 3 months' notice (VVG Art. 35a). Assumed to apply to contracts from before 2022 too; check your policy.",
                       isAssumption: true),
        ContractPreset(id: "chHealthKVG", name: "Swiss basic health insurance (KVG)", renewalMonths: 12, autoRenews: true,
                       notice: NoticePeriod(value: 1, unit: .months), fixedEndMonth: 12, fixedEndDay: 31,
                       note: "Notice must arrive by 30 November to switch on 1 January. With the standard model and the standard deductible, you can also switch on 30 June, with notice arriving by 31 March. Check KVG Art. 7.",
                       isAssumption: true),
        ContractPreset(id: "chRental", name: "Swiss flat rental", renewalMonths: 12, autoRenews: true,
                       notice: NoticePeriod(value: 3, unit: .months), fixedEndMonth: 0, fixedEndDay: 0,
                       note: "Notice must arrive 3 months before one of the local end-of-term dates (OR Art. 266c). Local dates vary; check your lease.",
                       isAssumption: true),
        ContractPreset(id: "mobileInternetCH", name: "Mobile or internet (Switzerland)", renewalMonths: 12, autoRenews: true,
                       notice: NoticePeriod(value: 2, unit: .months), fixedEndMonth: 0, fixedEndDay: 0,
                       note: "Typically 2 months' notice to the end of the term. Check your contract.",
                       isAssumption: true),
        ContractPreset(id: "mobileInternetUK", name: "Mobile or broadband (UK)", renewalMonths: 1, autoRenews: true,
                       notice: NoticePeriod(value: 30, unit: .days), fixedEndMonth: 0, fixedEndDay: 0,
                       note: "Typically 30 days' notice once the minimum term has ended; the contract then runs month to month. Check your contract.",
                       isAssumption: true),
        ContractPreset(id: "subscriptionMonthly", name: "Monthly subscription", renewalMonths: 1, autoRenews: true,
                       notice: NoticePeriod(value: 1, unit: .months), fixedEndMonth: 0, fixedEndDay: 0,
                       note: "Renews every month. Check the notice period in the terms.",
                       isAssumption: false),
        ContractPreset(id: "deAfterMinimum", name: "Germany, after the minimum term", renewalMonths: 1, autoRenews: true,
                       notice: NoticePeriod(value: 1, unit: .months), fixedEndMonth: 0, fixedEndDay: 0,
                       note: "Since March 2022, a contract that renews after its minimum term can be ended at any time with 1 month's notice (§ 309 Nr. 9 BGB).",
                       isAssumption: true),
        ContractPreset(id: "ukAnnualInsurance", name: "UK annual insurance", renewalMonths: 12, autoRenews: true,
                       notice: NoticePeriod(value: 0, unit: .days), fixedEndMonth: 0, fixedEndDay: 0,
                       note: "Policies usually renew automatically with no notice period. You get a 'renews on' reminder so you can compare prices first.",
                       isAssumption: false),
        ContractPreset(id: "custom", name: "Custom", renewalMonths: 12, autoRenews: true,
                       notice: NoticePeriod(value: 3, unit: .months), fixedEndMonth: 0, fixedEndDay: 0,
                       note: "Enter the term, renewal and notice period from your contract.",
                       isAssumption: false),
    ]
}

extension ContractPreset {
    /// Tolerant: only `id` is required. Missing or unreadable fields come from
    /// the built-in preset with that id, or from 'custom'.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let base = ContractPreset.standard.first(where: { $0.id == id })
            ?? ContractPreset.standard.first(where: { $0.id == "custom" })
            ?? ContractPreset(id: id, name: "", renewalMonths: 12, autoRenews: true,
                              notice: NoticePeriod(value: 3, unit: .months), fixedEndMonth: 0, fixedEndDay: 0,
                              note: "", isAssumption: false)
        self.init(
            id: id,
            name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? base.name,
            renewalMonths: (try? c.decodeIfPresent(Int.self, forKey: .renewalMonths)) ?? base.renewalMonths,
            autoRenews: (try? c.decodeIfPresent(Bool.self, forKey: .autoRenews)) ?? base.autoRenews,
            notice: (try? c.decodeIfPresent(NoticePeriod.self, forKey: .notice)) ?? base.notice,
            fixedEndMonth: (try? c.decodeIfPresent(Int.self, forKey: .fixedEndMonth)) ?? base.fixedEndMonth,
            fixedEndDay: (try? c.decodeIfPresent(Int.self, forKey: .fixedEndDay)) ?? base.fixedEndDay,
            note: (try? c.decodeIfPresent(String.self, forKey: .note)) ?? base.note,
            isAssumption: (try? c.decodeIfPresent(Bool.self, forKey: .isAssumption)) ?? base.isAssumption
        )
    }
}

// MARK: - Legal notes

/// A plain-language note shown with an item's dates and in the evidence PDF.
struct LegalNote: Codable, Equatable {
    var text: String
    var basis: String
    var isAssumption: Bool
}

enum LegalNotes {
    static let disclaimer = "General information, not legal advice. Dates come from the defaults in Settings › Rules and may not fit your case. Check the shop's terms and your contract."

    /// The notes for an item, most urgent first. Contracts get contract notes
    /// only; receipts, invoices and warranty cards get the goods notes.
    static func notes(for j: Jurisdiction, channel: PurchaseChannel, kind: ItemKind, hasIssue: Bool, isUsed: Bool) -> [LegalNote] {
        if kind == .contract { return LegalNotes.contract(j) }
        switch j {
        case .englandWales, .scotland:
            return LegalNotes.uk(j, channel: channel, kind: kind, hasIssue: hasIssue, isUsed: isUsed)
        case .switzerland:
            return LegalNotes.swiss(channel: channel, kind: kind, hasIssue: hasIssue, isUsed: isUsed)
        case .eu:
            return LegalNotes.eu(channel: channel, kind: kind, hasIssue: hasIssue, isUsed: isUsed)
        }
    }

    /// A note whose basis is the RuleBases entry for `f`.
    private static func note(_ text: String, _ f: RuleField, _ j: Jurisdiction) -> LegalNote {
        let b = RuleBases.basis(f, j)
        return LegalNote(text: text, basis: b.basis, isAssumption: b.isAssumption)
    }

    private static func uk(_ j: Jurisdiction, channel: PurchaseChannel, kind: ItemKind, hasIssue: Bool, isUsed: Bool) -> [LegalNote] {
        var out: [LegalNote] = []
        if hasIssue {
            out.append(LegalNote(text: "You have noted a fault. Tell the seller in writing and keep a copy. Within the first 30 days you can reject the goods for a full refund; after that, the seller gets one chance to repair or replace them.",
                                 basis: "Consumer Rights Act 2015, ss.20–24", isAssumption: false))
        }
        out.append(note("Faulty goods can be rejected for a full refund within 30 days of delivery.", .rightToRejectDays, j))
        out.append(note("A fault that shows within 6 months is taken to have been there at delivery, unless the seller proves otherwise.", .faultPresumptionMonths, j))
        switch channel {
        case .store:
            out.append(note("Returning goods that are not faulty depends on the shop's policy; it is not a legal right.", .returnDaysStore, j))
        case .online:
            out.append(note("Most online orders can be cancelled within 14 days of delivery, without giving a reason.", .cancellationDaysOnline, j))
        case .doorstep:
            out.append(note("Doorstep and phone purchases can be cancelled within 14 days, without giving a reason.", .cancellationDaysDoorstep, j))
        }
        if isUsed {
            out.append(LegalNote(text: "Second-hand goods are covered too, allowing for their age and condition.",
                                 basis: "Consumer Rights Act 2015, s.9", isAssumption: false))
        }
        let years = j == .scotland ? 5 : 6
        out.append(note("A claim for faulty goods can generally be made for up to \(years) years.", .claimLimitYears, j))
        if kind == .warranty {
            out.append(LegalNote(text: "A manufacturer's warranty is extra; it does not replace your rights against the seller.",
                                 basis: "Consumer Rights Act 2015, s.30", isAssumption: false))
        }
        return out
    }

    private static func swiss(channel: PurchaseChannel, kind: ItemKind, hasIssue: Bool, isUsed: Bool) -> [LegalNote] {
        let j = Jurisdiction.switzerland
        var out: [LegalNote] = []
        if hasIssue {
            out.append(LegalNote(text: "You have noted a fault: report the defect promptly, in writing (OR Art. 201), and keep a copy.",
                                 basis: "OR Art. 201", isAssumption: false))
        }
        out.append(note("The seller is liable for defects for 2 years, but its terms may limit or replace this, for example with repair only (OR Art. 199).", .legalGuaranteeMonths, j))
        out.append(LegalNote(text: "Check the goods when you get them and report any defect as soon as you find it, in writing (OR Art. 201). A late report can cost you your rights.",
                             basis: "OR Art. 201", isAssumption: false))
        if isUsed {
            out.append(note("For used goods the seller may shorten the guarantee to 1 year by agreement.", .usedGoodsGuaranteeMonths, j))
        }
        switch channel {
        case .store:
            out.append(note("Returning goods that are not faulty is goodwill by the shop, not a legal right.", .returnDaysStore, j))
        case .online:
            out.append(note("Swiss law gives no general right to cancel an online order; check the shop's terms.", .cancellationDaysOnline, j))
        case .doorstep:
            out.append(note("Doorstep and phone purchases can be cancelled within 14 days, in writing (OR Art. 40a–40f).", .cancellationDaysDoorstep, j))
        }
        if kind == .warranty {
            out.append(LegalNote(text: "A manufacturer's warranty is extra; the seller's liability for defects still applies.",
                                 basis: "OR Art. 197–210", isAssumption: false))
        }
        return out
    }

    private static func eu(channel: PurchaseChannel, kind: ItemKind, hasIssue: Bool, isUsed: Bool) -> [LegalNote] {
        let j = Jurisdiction.eu
        var out: [LegalNote] = []
        if hasIssue {
            out.append(LegalNote(text: "You have noted a fault: tell the seller, ask for a repair or replacement, and keep a copy of what you send.",
                                 basis: "Directive (EU) 2019/771 Art. 13", isAssumption: false))
        }
        out.append(note("The seller is liable for defects that show within 2 years of delivery. This is a minimum; some countries give more.", .legalGuaranteeMonths, j))
        out.append(note("A defect that shows within the first year is presumed to have been there at delivery; some countries allow 2 years.", .faultPresumptionMonths, j))
        if isUsed {
            out.append(note("For used goods the seller may shorten the guarantee to 1 year by agreement.", .usedGoodsGuaranteeMonths, j))
        }
        switch channel {
        case .store:
            out.append(note("Returning goods that are not faulty is goodwill by the shop, not a legal right.", .returnDaysStore, j))
        case .online:
            out.append(note("You can withdraw from an online order within 14 days of delivery, without giving a reason.", .cancellationDaysOnline, j))
        case .doorstep:
            out.append(note("You can withdraw from a doorstep or phone purchase within 14 days, without giving a reason.", .cancellationDaysDoorstep, j))
        }
        if kind == .warranty {
            out.append(LegalNote(text: "A manufacturer's warranty is extra; it does not replace the seller's legal guarantee.",
                                 basis: "Directive (EU) 2019/771 Art. 17", isAssumption: false))
        }
        return out
    }

    private static func contract(_ j: Jurisdiction) -> [LegalNote] {
        var out: [LegalNote] = [
            LegalNote(text: "It is the day your notice arrives that counts. Send it by registered post (Einschreiben / recommandé) and keep the receipt.",
                      basis: "Usual contract terms; check yours", isAssumption: true),
            LegalNote(text: "'Send by' leaves a few working days for the post, counting Monday to Friday; public holidays are not taken into account.",
                      basis: "Postal buffer set in Settings; no holiday tables", isAssumption: true),
        ]
        switch j {
        case .switzerland:
            out.append(LegalNote(text: "Insurance contracts running longer than 3 years can also be ended at the end of the third year, with 3 months' notice.",
                                 basis: "VVG Art. 35a; assumed for contracts from before 2022", isAssumption: true))
        case .eu:
            out.append(LegalNote(text: "In Germany, a contract that renews after its minimum term can be ended at any time with 1 month's notice.",
                                 basis: "§ 309 Nr. 9 BGB, since March 2022", isAssumption: true))
        case .englandWales, .scotland:
            out.append(LegalNote(text: "Mobile and broadband contracts usually need 30 days' notice once the minimum term has ended. Many insurance policies renew automatically, so compare prices before the renewal date.",
                                 basis: "Typical provider terms; check yours", isAssumption: true))
        }
        return out
    }
}

// MARK: - Rule book

/// Everything the planner reads, stored as tolerant JSON in the settings.
/// Dictionary keys are Jurisdiction and DeadlineKind raw values.
struct RuleBook: Codable, Equatable {
    var version: Int
    var rules: [String: JurisdictionRules]
    var presets: [ContractPreset]
    /// Lead times in days before each kind of date.
    var offsets: [String: [Int]]
    var remindByDefault: [String: Bool]
    /// Items below this total get no reminders, except contracts and warranty
    /// cards. 0 = off.
    var minReminderMinor: Int64
    /// Working days between 'Send by' and 'Notice must arrive by'.
    var postalBufferDays: Int

    static let defaults: RuleBook = {
        var rules: [String: JurisdictionRules] = [:]
        for j in Jurisdiction.allCases { rules[j.rawValue] = JurisdictionRules.standard(j) }
        var offsets: [String: [Int]] = [:]
        var reminds: [String: Bool] = [:]
        for k in DeadlineKind.allCases {
            offsets[k.rawValue] = RuleBook.standardOffsets(k)
            reminds[k.rawValue] = RuleBook.standardRemind(k)
        }
        return RuleBook(version: 1, rules: rules, presets: ContractPreset.standard, offsets: offsets,
                        remindByDefault: reminds, minReminderMinor: 0, postalBufferDays: 5)
    }()

    static func standardOffsets(_ k: DeadlineKind) -> [Int] {
        switch k {
        case .returnWindow, .cancellation: return [3, 1]
        case .rightToReject: return [5, 1]
        case .faultPresumption: return [30]
        case .manufacturerWarranty: return [30, 7]
        case .legalGuarantee: return [30]
        case .claimLimit: return [90]
        case .noticeDeadline: return [30, 14, 3]
        case .termEnd: return [30, 7]
        case .custom: return [7]
        }
    }

    static func standardRemind(_ k: DeadlineKind) -> Bool {
        switch k {
        case .returnWindow, .cancellation, .manufacturerWarranty, .legalGuarantee, .noticeDeadline, .custom: return true
        case .rightToReject, .faultPresumption, .claimLimit, .termEnd: return false
        }
    }

    /// Falls back to the built-in defaults.
    func rules(for j: Jurisdiction) -> JurisdictionRules {
        self.rules[j.rawValue] ?? JurisdictionRules.standard(j)
    }

    func offsets(for k: DeadlineKind) -> [Int] {
        self.offsets[k.rawValue] ?? RuleBook.standardOffsets(k)
    }

    func remindsByDefault(_ k: DeadlineKind) -> Bool {
        self.remindByDefault[k.rawValue] ?? RuleBook.standardRemind(k)
    }

    func preset(id: String) -> ContractPreset? {
        presets.first(where: { $0.id == id })
    }

    /// The stored book laid over the defaults: dictionaries merge key by key,
    /// arrays and scalars are replaced, nulls and unknown jurisdictions or
    /// deadline kinds are ignored. Anything unreadable gives the defaults, so
    /// an older JSON simply picks up fields added since.
    static func decode(_ data: Data?) -> RuleBook {
        guard let data = data, !data.isEmpty,
              let user = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let base = (try? JSONSerialization.jsonObject(with: RuleBook.defaults.encoded())) as? [String: Any] else {
            return RuleBook.defaults
        }
        var merged = RuleBook.merge(user, over: base)
        let places = Set(Jurisdiction.allCases.map { $0.rawValue })
        let kinds = Set(DeadlineKind.allCases.map { $0.rawValue })
        RuleBook.keep(places, under: "rules", in: &merged)
        RuleBook.keep(kinds, under: "offsets", in: &merged)
        RuleBook.keep(kinds, under: "remindByDefault", in: &merged)
        guard JSONSerialization.isValidJSONObject(merged),
              let json = try? JSONSerialization.data(withJSONObject: merged),
              let book = try? JSONDecoder().decode(RuleBook.self, from: json) else {
            return RuleBook.defaults
        }
        return book
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// `top` over `base`: nested dictionaries merge recursively; arrays,
    /// scalars and mismatched types replace; nulls are skipped.
    private static func merge(_ top: [String: Any], over base: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in top {
            if value is NSNull { continue }
            if let inner = value as? [String: Any], let existing = result[key] as? [String: Any] {
                result[key] = RuleBook.merge(inner, over: existing)
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// Drops the keys of `object[key]` that are not in `known`.
    private static func keep(_ known: Set<String>, under key: String, in object: inout [String: Any]) {
        guard let inner = object[key] as? [String: Any] else { return }
        object[key] = inner.filter { known.contains($0.key) }
    }
}

// MARK: - Planner

/// What the planner needs to know about an item. `contract` is set only for
/// contracts with a term end.
struct PurchaseFacts: Equatable {
    var kind: ItemKind
    var purchaseDate: DayDate
    var deliveryDate: DayDate?
    var jurisdiction: Jurisdiction
    var channel: PurchaseChannel
    var category: ProductCategory
    var isUsed: Bool
    var hasIssue: Bool
    var totalMinor: Int64?
    var warrantyMonths: Int?
    var warrantyIsPrinted: Bool
    var returnDays: Int?
    var returnDaysIsPrinted: Bool
    var contract: ContractFacts?
}

/// One key date, before it becomes a Deadline row.
struct PlannedDeadline: Equatable {
    var kind: DeadlineKind
    var date: DayDate
    var remindByDefault: Bool
    /// Lead times in days before `date`, largest first.
    var offsets: [Int]
    var basis: String
    var certainty: Certainty
}

/// Turns facts and rules into key dates. Legal periods run from the delivery
/// date when it is set, otherwise from purchase; the shop return window (in
/// store) and the manufacturer warranty run from purchase. Day periods end
/// on start + N days, month and year periods the day before the anniversary.
enum DeadlinePlanner {
    /// A manufacturer warranty ending this close to the legal guarantee does
    /// not remind; the legal guarantee does.
    static let quietWithinDays = 7

    /// Counts are capped here, so wild values cannot overflow the day maths.
    private static let maxDays = 36_600
    private static let maxMonths = 1_200
    private static let maxYears = 100

    /// Sorted by date, one entry per kind.
    static func plan(_ f: PurchaseFacts, rules: RuleBook, today: DayDate) -> [PlannedDeadline] {
        let isContract = f.kind == .contract || f.contract != nil
        var planned: [PlannedDeadline]
        if isContract {
            if let c = f.contract {
                planned = DeadlinePlanner.contractDates(c, book: rules, today: today)
            } else {
                planned = []
            }
        } else {
            planned = DeadlinePlanner.goodsDates(f, book: rules)
        }

        // The optional minimum amount never applies to contracts or warranty cards.
        let exempt = isContract || f.kind == .warranty
        if !exempt, rules.minReminderMinor > 0, let total = f.totalMinor, total < rules.minReminderMinor {
            for i in planned.indices { planned[i].remindByDefault = false }
        }

        let order = DeadlineKind.allCases
        planned.sort { a, b in
            if a.date != b.date { return a.date < b.date }
            return (order.firstIndex(of: a.kind) ?? 0) < (order.firstIndex(of: b.kind) ?? 0)
        }
        var seen = Set<DeadlineKind>()
        return planned.filter { seen.insert($0.kind).inserted }
    }

    // MARK: Goods

    private static func goodsDates(_ f: PurchaseFacts, book: RuleBook) -> [PlannedDeadline] {
        let j = f.jurisdiction
        let r = book.rules(for: j)
        let start = f.deliveryDate ?? f.purchaseDate
        let goods = f.category.tracksGoodsDates
        var out: [PlannedDeadline] = []

        func add(_ kind: DeadlineKind, _ date: DayDate, _ remind: Bool, _ origin: Origin) {
            out.append(PlannedDeadline(kind: kind, date: date, remindByDefault: remind,
                                       offsets: DeadlinePlanner.cleaned(book.offsets(for: kind)),
                                       basis: origin.basis, certainty: origin.certainty))
        }

        // Shop return window: the shop's default in store (from purchase);
        // online, doorstep or for non-goods only when printed or entered.
        let storeDefault: Int? = (goods && f.channel == .store) ? r.returnDaysStore : nil
        if let rawDays = f.returnDays ?? storeDefault {
            let days = DeadlinePlanner.boundDays(rawDays)
            if days > 0 {
                let returnStart = f.channel == .store ? f.purchaseDate : start
                let origin = f.returnDays != nil
                    ? DeadlinePlanner.fromItem(days, unit: "days", printed: f.returnDaysIsPrinted)
                    : DeadlinePlanner.fromRules(.returnDaysStore, r, j)
                add(.returnWindow, RVCalendar.periodEnd(from: returnStart, days: days), book.remindsByDefault(.returnWindow), origin)
            }
        }

        if goods {
            // 14-day cancellation, online and doorstep only.
            let cancelField: RuleField?
            switch f.channel {
            case .store: cancelField = nil
            case .online: cancelField = .cancellationDaysOnline
            case .doorstep: cancelField = .cancellationDaysDoorstep
            }
            if let field = cancelField {
                let days = DeadlinePlanner.boundDays(r.value(field))
                if days > 0 {
                    add(.cancellation, RVCalendar.periodEnd(from: start, days: days), book.remindsByDefault(.cancellation),
                        DeadlinePlanner.fromRules(field, r, j))
                }
            }

            // Right to reject: reminds only when a fault has been noted.
            let reject = DeadlinePlanner.boundDays(r.rightToRejectDays)
            if reject > 0 {
                add(.rightToReject, RVCalendar.periodEnd(from: start, days: reject),
                    f.hasIssue || book.remindsByDefault(.rightToReject),
                    DeadlinePlanner.fromRules(.rightToRejectDays, r, j))
            }

            let fault = DeadlinePlanner.boundMonths(r.faultPresumptionMonths)
            if fault > 0 {
                add(.faultPresumption, RVCalendar.periodEnd(from: start, months: fault),
                    book.remindsByDefault(.faultPresumption),
                    DeadlinePlanner.fromRules(.faultPresumptionMonths, r, j))
            }
        }

        // Legal guarantee, with the used-goods period where one is set.
        var legalEnd: DayDate? = nil
        if goods {
            let field: RuleField = (f.isUsed && r.usedGoodsGuaranteeMonths > 0) ? .usedGoodsGuaranteeMonths : .legalGuaranteeMonths
            let months = DeadlinePlanner.boundMonths(r.value(field))
            if months > 0 {
                let end = RVCalendar.periodEnd(from: start, months: months)
                legalEnd = end
                add(.legalGuarantee, end, book.remindsByDefault(.legalGuarantee), DeadlinePlanner.fromRules(field, r, j))
            }
        }

        // Manufacturer warranty, from purchase: printed or entered, else the
        // default for electronics and appliances.
        let defaultWarranty: Int? = (goods && f.category.usesManufacturerDefault) ? r.manufacturerWarrantyMonths : nil
        if let rawMonths = f.warrantyMonths ?? defaultWarranty {
            let months = DeadlinePlanner.boundMonths(rawMonths)
            if months > 0 {
                let end = RVCalendar.periodEnd(from: f.purchaseDate, months: months)
                var remind = book.remindsByDefault(.manufacturerWarranty)
                if let legal = legalEnd, abs(RVCalendar.daysBetween(end, legal)) <= DeadlinePlanner.quietWithinDays {
                    remind = false
                }
                let origin = f.warrantyMonths != nil
                    ? DeadlinePlanner.fromItem(months, unit: "months", printed: f.warrantyIsPrinted)
                    : DeadlinePlanner.fromRules(.manufacturerWarrantyMonths, r, j)
                add(.manufacturerWarranty, end, remind, origin)
            }
        }

        if goods {
            let years = min(max(r.claimLimitYears, 0), DeadlinePlanner.maxYears)
            if years > 0 {
                add(.claimLimit, RVCalendar.periodEnd(from: start, months: years * 12),
                    book.remindsByDefault(.claimLimit),
                    DeadlinePlanner.fromRules(.claimLimitYears, r, j))
            }
        }
        return out
    }

    // MARK: Contracts

    /// The notice deadline (with a reminder on the send-by day) and the end
    /// of the current term. Zero notice, cancelled or non-renewing contracts
    /// get only the term end, and it reminds.
    private static func contractDates(_ c: ContractFacts, book: RuleBook, today: DayDate) -> [PlannedDeadline] {
        let status = ContractMath.status(c, today: today, postalBufferDays: book.postalBufferDays)
        let endOffsets = DeadlinePlanner.cleaned(book.offsets(for: .termEnd))

        if status.endsWithoutRenewal || c.notice.value <= 0 {
            let basis: String
            if c.cancelled {
                basis = "Cancelled: the contract ends on this day."
            } else if status.endsWithoutRenewal {
                basis = "Does not renew: the contract ends on this day."
            } else {
                basis = "Renews on this day. No notice period is set, so check the price before then."
            }
            return [PlannedDeadline(kind: .termEnd, date: status.termEnd, remindByDefault: true,
                                    offsets: endOffsets, basis: basis, certainty: .user)]
        }

        let postDays = RVCalendar.daysBetween(status.sendBy, status.noticeBy)
        let noticeOffsets = DeadlinePlanner.cleaned(book.offsets(for: .noticeDeadline) + [postDays])
        let possessive = c.notice.value == 1 ? "'s" : "'"
        let noticeBasis = "\(c.notice.label)\(possessive) notice before the term ends, as entered. It is the day notice arrives that counts."
        let every = c.renewalMonths == 1 ? "every month" : "every \(c.renewalMonths) months"
        let endBasis = "Renews \(every) unless notice arrives in time."
        return [
            PlannedDeadline(kind: .noticeDeadline, date: status.noticeBy,
                            remindByDefault: book.remindsByDefault(.noticeDeadline),
                            offsets: noticeOffsets, basis: noticeBasis, certainty: .user),
            PlannedDeadline(kind: .termEnd, date: status.termEnd,
                            remindByDefault: book.remindsByDefault(.termEnd),
                            offsets: endOffsets, basis: endBasis, certainty: .user),
        ]
    }

    // MARK: Helpers

    private struct Origin {
        var basis: String
        var certainty: Certainty
    }

    /// A value printed on the document or entered on the item.
    private static func fromItem(_ value: Int, unit: String, printed: Bool) -> Origin {
        let length = DeadlinePlanner.amount(value, unit)
        return printed
            ? Origin(basis: "\(length), from the document", certainty: .printed)
            : Origin(basis: "\(length), entered by you", certainty: .user)
    }

    /// A RuleBook value: 'You' when it differs from the built-in default,
    /// otherwise law or assumption from RuleBases.
    private static func fromRules(_ field: RuleField, _ rules: JurisdictionRules, _ j: Jurisdiction) -> Origin {
        let value = rules.value(field)
        if value != RuleBook.defaults.rules(for: j).value(field) {
            return Origin(basis: "\(DeadlinePlanner.amount(value, field.unit)), your setting in Settings › Rules", certainty: .user)
        }
        let b = RuleBases.basis(field, j)
        return Origin(basis: b.basis, certainty: b.isAssumption ? .assumption : .law)
    }

    /// '1 day', '36 months'.
    private static func amount(_ n: Int, _ unit: String) -> String {
        n == 1 ? "1 \(String(unit.dropLast()))" : "\(n) \(unit)"
    }

    /// Non-negative, within the cap, without repeats, largest first.
    private static func cleaned(_ offsets: [Int]) -> [Int] {
        let kept = offsets.filter { $0 >= 0 && $0 <= DeadlinePlanner.maxDays }
        return Array(Set(kept)).sorted(by: >)
    }

    private static func boundDays(_ n: Int) -> Int {
        min(max(n, 0), DeadlinePlanner.maxDays)
    }

    private static func boundMonths(_ n: Int) -> Int {
        min(max(n, 0), DeadlinePlanner.maxMonths)
    }
}
