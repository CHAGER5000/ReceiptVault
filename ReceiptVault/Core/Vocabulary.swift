import Foundation

// Shared vocabulary. Every raw value below is persisted (SwiftData, settings,
// rules JSON and backups), so raw values are frozen once released: add cases,
// never rename or remove them.

// MARK: - Items

/// What kind of document an item is.
enum ItemKind: String, CaseIterable, Codable, Identifiable {
    case receipt, invoice, warranty, contract
    var id: String { rawValue }
    var label: String {
        switch self {
        case .receipt: return "Receipt"
        case .invoice: return "Invoice"
        case .warranty: return "Warranty card"
        case .contract: return "Contract"
        }
    }
    /// SF Symbol name.
    var symbol: String {
        switch self {
        case .receipt: return "receipt"
        case .invoice: return "doc.text"
        case .warranty: return "checkmark.seal"
        case .contract: return "signature"
        }
    }
}

/// Whose consumer rules apply to a purchase.
enum Jurisdiction: String, CaseIterable, Codable, Identifiable {
    case englandWales, scotland, switzerland, eu
    var id: String { rawValue }
    var label: String {
        switch self {
        case .englandWales: return "UK – England, Wales & NI"
        case .scotland: return "UK – Scotland"
        case .switzerland: return "Switzerland"
        case .eu: return "EU"
        }
    }
    /// ISO 4217 code suggested for new items.
    var defaultCurrency: String {
        switch self {
        case .englandWales, .scotland: return "GBP"
        case .switzerland: return "CHF"
        case .eu: return "EUR"
        }
    }
}

/// Where the purchase was made; decides cancellation rights.
enum PurchaseChannel: String, CaseIterable, Codable, Identifiable {
    case store, online, doorstep
    var id: String { rawValue }
    var label: String {
        switch self {
        case .store: return "In store"
        case .online: return "Online"
        case .doorstep: return "Doorstep or phone"
        }
    }
}

/// What was bought; decides which goods dates are planned.
enum ProductCategory: String, CaseIterable, Codable, Identifiable {
    case electronics, appliance, furniture, clothing, homeGarden, sportLeisure, vehicle, otherGoods
    case groceries, service, expense
    var id: String { rawValue }
    var label: String {
        switch self {
        case .electronics: return "Electronics"
        case .appliance: return "Appliances"
        case .furniture: return "Furniture"
        case .clothing: return "Clothing & shoes"
        case .homeGarden: return "Home & garden"
        case .sportLeisure: return "Sport & leisure"
        case .vehicle: return "Vehicles & parts"
        case .otherGoods: return "Other goods"
        case .groceries: return "Food & groceries"
        case .service: return "Service"
        case .expense: return "Expense only (no dates)"
        }
    }
    /// False for groceries, services and expense-only items: they get goods
    /// dates only when a return period or warranty is printed or entered.
    var tracksGoodsDates: Bool {
        switch self {
        case .groceries, .service, .expense: return false
        default: return true
        }
    }
    /// True when the RuleBook's manufacturer warranty applies without a
    /// printed or entered one.
    var usesManufacturerDefault: Bool {
        switch self {
        case .electronics, .appliance: return true
        default: return false
        }
    }
}

// MARK: - Deadlines

/// A kind of date on an item's timeline.
enum DeadlineKind: String, CaseIterable, Codable, Identifiable {
    case returnWindow, cancellation, rightToReject, faultPresumption, manufacturerWarranty
    case legalGuarantee, claimLimit, noticeDeadline, termEnd, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .returnWindow: return "Shop return window"
        case .cancellation: return "14-day cancellation"
        case .rightToReject: return "Right to reject"
        case .faultPresumption: return "Fault presumption"
        case .manufacturerWarranty: return "Manufacturer warranty"
        case .legalGuarantee: return "Legal guarantee"
        case .claimLimit: return "Claim time limit"
        case .noticeDeadline: return "Notice deadline"
        case .termEnd: return "Contract end"
        case .custom: return "Custom date"
        }
    }
    /// Short text shown before the date, e.g. 'Return by 9 Apr 2026'.
    var dueWording: String {
        switch self {
        case .returnWindow: return "Return by"
        case .cancellation: return "Cancel by"
        case .rightToReject: return "Reject by"
        case .faultPresumption: return "Fault presumed until"
        case .manufacturerWarranty: return "Warranty ends"
        case .legalGuarantee: return "Legal guarantee ends"
        case .claimLimit: return "Claim limit"
        case .noticeDeadline: return "Notice must arrive by"
        case .termEnd: return "Contract ends"
        case .custom: return "Due"
        }
    }
    /// SF Symbol name.
    var symbol: String {
        switch self {
        case .returnWindow: return "arrow.uturn.backward"
        case .cancellation: return "xmark.circle"
        case .rightToReject: return "hand.raised"
        case .faultPresumption: return "exclamationmark.triangle"
        case .manufacturerWarranty: return "checkmark.seal"
        case .legalGuarantee: return "shield"
        case .claimLimit: return "hourglass"
        case .noticeDeadline: return "envelope"
        case .termEnd: return "calendar.badge.clock"
        case .custom: return "calendar"
        }
    }
}

/// Where a date or value comes from.
enum Certainty: String, CaseIterable, Codable {
    case law, assumption, printed, user
    var label: String {
        switch self {
        case .law: return "Law"
        case .assumption: return "Assumed"
        case .printed: return "From document"
        case .user: return "You"
        }
    }
}

// MARK: - Tax

/// Which tax return(s) an entry is claimable in. Raw values and labels match
/// LocalLedger exactly.
enum TaxTag: String, CaseIterable, Codable, Identifiable {
    case none, uk, ch, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Not claimable"
        case .uk: return "UK"
        case .ch: return "Switzerland"
        case .both: return "UK and Switzerland"
        }
    }
}

// MARK: - Files

/// How a stored file reached the vault.
enum FileSource: String, CaseIterable, Codable {
    case scan, photos, files, openIn, restored
    var label: String {
        switch self {
        case .scan: return "Camera scan"
        case .photos: return "Photo library"
        case .files: return "Files"
        case .openIn: return "Shared to ReceiptVault"
        case .restored: return "Restored from backup"
        }
    }
}

// MARK: - Contracts

/// A contract's notice period, e.g. 3 months or 30 days. A value of 0 means
/// no notice is needed.
struct NoticePeriod: Codable, Equatable, Hashable {
    enum Unit: String, Codable, CaseIterable {
        case days, weeks, months
    }
    var value: Int
    var unit: Unit

    /// '3 months', '1 month', '30 days', '1 week'; 'No notice' for 0.
    var label: String {
        if value <= 0 { return "No notice" }
        let word: String
        switch unit {
        case .days: word = value == 1 ? "day" : "days"
        case .weeks: word = value == 1 ? "week" : "weeks"
        case .months: word = value == 1 ? "month" : "months"
        }
        return "\(value) \(word)"
    }
}
