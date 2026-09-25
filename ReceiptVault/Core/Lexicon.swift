import Foundation

// Keyword lists for reading receipts, invoices, warranty cards and contracts in
// English, German, French and Italian, plus the known-merchant catalogue and a
// few small tables. Every word list is stored already folded (lowercase, no
// accents, one space between words: see TextFold.fold), so a match is a plain
// TextFold.containsWord on the folded document text. Data only, no logic.
// Plain arrays, never Set or Dictionary literals, so a repeated entry can never
// crash at launch.

enum Lexicon {

    // MARK: - Totals

    /// Labels that name the amount actually paid.
    static let totalStrong: [String] = [
        "total to pay", "amount due", "balance due", "grand total", "total ttc", "net a payer", "montant du",
        "zu bezahlen", "zahlbetrag", "gesamtbetrag", "rechnungsbetrag", "endbetrag", "total chf", "total eur",
        "total gbp", "totale", "importo totale",
        "total due", "total payable", "amount payable", "amount to pay", "balance to pay", "order total",
        "invoice total", "total fr", "total a payer", "montant a payer", "montant ttc", "zu zahlen",
        "gesamtsumme", "endsumme", "totalbetrag", "rechnungstotal", "totale complessivo", "totale euro",
        "totale da pagare", "importo da pagare",
    ]

    /// Labels that usually, but not always, name the total.
    static let totalNormal: [String] = [
        "total", "gesamt", "summe", "betrag", "montant", "a payer", "to pay", "totale",
        "total amount", "montant total", "gesamtpreis", "bruttobetrag", "importo pagato",
    ]

    /// Labels of amounts that are never the total: subtotals, net amounts, tax,
    /// discounts, item counts, cash handed over and change, tips and points.
    static let totalExcluded: [String] = [
        "subtotal", "sub-total", "sub total", "zwischensumme", "sous-total", "total ht", "hors taxe", "netto",
        "net", "excl", "exkl", "vat", "v.a.t", "mwst", "ust", "tva", "iva", "savings", "you saved", "discount",
        "rabatt", "remise", "sconto", "items", "artikel", "change", "ruckgeld", "rendu", "cash tendered",
        "tendered", "gegeben", "recu", "tip", "trinkgeld", "points", "punkte",
        "sous total", "subtotale", "zwischentotal", "nettobetrag", "imponibile", "excluding", "mehrwertsteuer",
        "umsatzsteuer", "steuerbetrag", "reduction", "promo", "promotion", "aktion", "coupon", "voucher",
        "gutschein", "clubcard", "nectar", "pfand", "deposit", "rounding", "rundung", "arrondi", "cashback",
        "articles", "articoli", "rueckgeld", "wechselgeld", "zuruck", "resto", "gratuity", "pourboire", "mancia",
        "punti",
    ]

    /// Card and wallet payment lines; the amount on them corroborates the total.
    static let paymentWords: [String] = [
        "visa", "mastercard", "maestro", "amex", "card", "karte", "carte", "contactless", "twint", "apple pay",
        "google pay", "postfinance", "debit", "ec",
        "american express", "v pay", "vpay", "girocard", "kreditkarte", "debitkarte", "carte bancaire", "cb",
        "bancomat", "pagobancomat", "carta di credito", "carta di debito", "samsung pay", "paypal", "kontaktlos",
        "sans contact", "chip and pin", "chip & pin",
    ]

    /// Cash handed over and change given back.
    static let changeWords: [String] = [
        "change", "ruckgeld", "rendu", "cash", "bar", "especes", "tendered", "gegeben", "recu", "contanti",
        "rueckgeld", "wechselgeld", "zuruck", "zurueck", "resto", "monnaie", "bargeld",
    ]

    // MARK: - VAT

    /// Words on VAT lines (registration-number lines are filtered out separately).
    static let vatWords: [String] = [
        "vat", "v.a.t", "mwst", "mehrwertsteuer", "ust", "tva", "iva", "incl. tax", "inkl",
        "umsatzsteuer", "steuerbetrag", "imposta", "incl tax",
    ]

    // MARK: - Dates

    /// Labels of the purchase or invoice date, on the same line or the line above.
    static let purchaseDateLabels: [String] = [
        "date", "datum", "rechnungsdatum", "kaufdatum", "belegdatum", "bestelldatum", "date de facture",
        "date d achat", "date de commande", "order date", "invoice date", "tax point", "data",
        "date d'achat", "verkaufsdatum", "ausstellungsdatum", "auftragsdatum",
    ]

    /// Labels of the delivery date, which fills the delivery date instead.
    static let deliveryDateLabels: [String] = [
        "delivery date", "delivered", "dispatch date", "lieferdatum", "geliefert", "date de livraison", "livre le",
        "data di consegna",
        "date of delivery", "dispatched", "versanddatum", "liefertermin", "leistungsdatum", "date d'expedition",
        "date d expedition", "livraison le", "data consegna", "consegnato",
    ]

    /// Labels of dates that are never the purchase date: payment due, validity,
    /// expiry, best before, return-by and renewal dates.
    static let negativeDateLabels: [String] = [
        "due", "payable by", "fallig", "zahlbar bis", "echeance", "valid until", "gultig bis", "valable jusqu",
        "expires", "expiry", "best before", "mhd", "scadenza",
        "falligkeitsdatum", "falligkeit", "faellig", "zahlungsziel", "pay by", "a payer avant", "da pagare entro",
        "valid to", "gueltig bis", "valido fino", "expiration", "use by", "haltbar", "a consommer",
        "da consumarsi", "return by", "exchange by", "umtausch bis", "ruckgabe bis", "retour avant", "renewal",
        "renews", "next payment", "end date", "ablaufdatum", "enddatum",
    ]

    // MARK: - Kind and channel

    /// Contracts and insurance policies.
    static let contractWords: [String] = [
        "vertrag", "police", "policy schedule", "contrat", "abonnement", "laufzeit", "kundigung", "resiliation",
        "contratto", "insurance policy", "versicherung", "assurance",
        "kuendigung", "kundigungsfrist", "mindestlaufzeit", "vertragslaufzeit", "vertragsbeginn", "vertragsnummer",
        "versicherungspolice", "versicherungsvertrag", "polizza", "disdetta", "duree du contrat",
        "delai de resiliation", "durata del contratto", "notice period", "minimum term", "contract term",
    ]

    /// Warranty cards and certificates.
    static let warrantyWords: [String] = [
        "warranty card", "garantiekarte", "garantieschein", "certificat de garantie", "bon de garantie",
        "certificato di garanzia",
        "guarantee card", "warranty certificate", "guarantee certificate", "garantiezertifikat",
        "garantieurkunde", "carte de garantie", "tagliando di garanzia",
    ]

    /// Invoices.
    static let invoiceWords: [String] = [
        "invoice", "tax invoice", "rechnung", "facture", "fattura",
        "rechnungsnummer", "rechnungsnr", "rechnungs-nr", "rechnungsdatum",
    ]

    /// Orders placed online or for delivery.
    static let onlineWords: [String] = [
        "order number", "order no", "bestellnummer", "numero de commande", "delivery", "shipping", "versand",
        "lieferung", "livraison", "spedizione",
        "order confirmation", "order id", "order ref", "online order", "bestellung", "bestellnr", "bestelldatum",
        "versandkosten", "lieferadresse", "lieferanschrift", "commande en ligne", "frais de port",
        "numero ordine", "dispatched",
    ]

    // MARK: - Merchant

    /// Headings and greetings that are never the merchant's name.
    static let documentWords: [String] = [
        "receipt", "tax invoice", "invoice", "rechnung", "quittung", "kassenbon", "beleg", "facture", "ticket",
        "ticket de caisse", "scontrino", "welcome", "willkommen", "bienvenue", "thank you", "danke", "merci",
        "thanks", "dank", "grazie", "benvenuti", "kassenbeleg", "kassenzettel", "kundenbeleg", "ricevuta",
        "fattura", "documento commerciale", "delivery note", "lieferschein", "bon de livraison",
        "order confirmation", "bestellbestatigung", "auftragsbestatigung", "confirmation de commande",
        "credit note", "gutschrift", "customer copy", "copy", "kopie", "copie", "duplicate", "duplikat",
        "duplicata", "page", "seite", "pagina",
    ]

    /// Company-form suffixes removed from the end of a merchant's name.
    static let legalSuffixes: [String] = [
        "ltd", "limited", "plc", "llp", "gmbh", "ag", "sa", "sarl", "sas", "kg", "spa", "srl", "bv", "nv",
        "inc", "llc", "se", "sagl", "ug", "ohg", "kgaa", "eurl", "s.a", "s.p.a", "s.r.l", "s.a.r.l", "b.v", "n.v",
    ]

    /// Shops and providers recognised anywhere in the text (word-bounded), with
    /// the name to show and the category to suggest. Grocers give .groceries, so
    /// no warranty dates are planned. Earlier entries win when several match:
    /// sub-brands come before their parent and manufacturers come last, so a
    /// brand in an item line never beats the shop. Bare brand words that also
    /// appear on payment or item lines ("apple", "samsung", "dyson", "boots")
    /// are deliberately not keys.
    static let knownMerchants: [(key: String, name: String, category: ProductCategory)] =
        merchantGroups.flatMap { $0 }

    private static let merchantGroups: [[(key: String, name: String, category: ProductCategory)]] = [
        // United Kingdom
        merchant("Currys", .electronics, "currys", "pc world", "pcworld"),
        merchant("Argos", .otherGoods, "argos"),
        merchant("Waitrose", .groceries, "waitrose"),
        merchant("John Lewis", .otherGoods, "john lewis", "johnlewis"),
        merchant("Richer Sounds", .electronics, "richer sounds", "richersounds"),
        merchant("AO.com", .appliance, "ao.com"),
        merchant("Halfords", .vehicle, "halfords"),
        merchant("B&Q", .homeGarden, "b&q", "diy.com"),
        merchant("Screwfix", .homeGarden, "screwfix"),
        merchant("Wickes", .homeGarden, "wickes"),
        merchant("Dunelm", .homeGarden, "dunelm"),
        merchant("Boots", .otherGoods, "boots uk", "boots.com", "boots advantage"),
        merchant("Superdrug", .otherGoods, "superdrug"),
        merchant("Primark", .clothing, "primark"),
        merchant("JD Sports", .sportLeisure, "jd sports", "jdsports"),
        merchant("Sports Direct", .sportLeisure, "sports direct", "sportsdirect"),
        merchant("Tesco Mobile", .service, "tesco mobile"),
        merchant("Tesco", .groceries, "tesco"),
        merchant("Sainsbury's", .groceries, "sainsbury", "sainsburys"),
        merchant("Asda", .groceries, "asda"),
        merchant("Morrisons", .groceries, "morrisons"),
        merchant("Ocado", .groceries, "ocado"),
        merchant("Co-op", .groceries, "co-op", "co-operative"),
        // Switzerland
        merchant("Digitec", .electronics, "digitec.ch"),
        merchant("Galaxus", .otherGoods, "galaxus.ch", "galaxus"),
        merchant("Digitec", .electronics, "digitec"),
        merchant("Interdiscount", .electronics, "interdiscount"),
        merchant("Fust", .appliance, "fust"),
        merchant("Brack.ch", .electronics, "brack.ch", "brack electronics"),
        merchant("Microspot", .electronics, "microspot"),
        merchant("melectronics", .electronics, "melectronics"),
        merchant("mobilezone", .electronics, "mobilezone"),
        merchant("Do it + Garden", .homeGarden, "do it + garden", "do it+garden"),
        merchant("Hornbach", .homeGarden, "hornbach"),
        merchant("Landi", .homeGarden, "landi"),
        merchant("Ochsner Sport", .sportLeisure, "ochsner sport"),
        merchant("Manor", .otherGoods, "manor ag", "manor.ch"),
        merchant("Coop City", .otherGoods, "coop city"),
        merchant("Coop Bau+Hobby", .homeGarden, "bau+hobby", "bau + hobby"),
        merchant("Denner", .groceries, "denner"),
        merchant("Migros", .groceries, "migros"),
        merchant("Coop", .groceries, "coop"),
        merchant("Volg", .groceries, "volg"),
        // Rest of Europe
        merchant("MediaMarkt", .electronics, "mediamarkt", "media markt"),
        merchant("Saturn", .electronics, "saturn"),
        merchant("MediaWorld", .electronics, "mediaworld"),
        merchant("Unieuro", .electronics, "unieuro"),
        merchant("Fnac", .electronics, "fnac"),
        merchant("Darty", .appliance, "darty"),
        merchant("Boulanger", .electronics, "boulanger.com", "boulanger sa"),
        merchant("Leroy Merlin", .homeGarden, "leroy merlin", "leroymerlin"),
        merchant("Castorama", .homeGarden, "castorama"),
        merchant("Decathlon", .sportLeisure, "decathlon"),
        merchant("IKEA", .furniture, "ikea"),
        merchant("H&M", .clothing, "h&m"),
        merchant("Zara", .clothing, "zara"),
        merchant("Uniqlo", .clothing, "uniqlo"),
        merchant("Lidl", .groceries, "lidl"),
        merchant("Aldi", .groceries, "aldi"),
        merchant("Carrefour", .groceries, "carrefour market", "carrefour city", "carrefour express",
                 "carrefour.fr", "carrefour.it"),
        merchant("Auchan", .groceries, "auchan"),
        merchant("E.Leclerc", .groceries, "e.leclerc", "e. leclerc"),
        merchant("Intermarché", .groceries, "intermarche"),
        merchant("Monoprix", .groceries, "monoprix"),
        merchant("REWE", .groceries, "rewe"),
        merchant("EDEKA", .groceries, "edeka"),
        merchant("Esselunga", .groceries, "esselunga"),
        merchant("Conad", .groceries, "conad"),
        // Online marketplaces
        merchant("Amazon", .otherGoods, "amazon"),
        merchant("eBay", .otherGoods, "ebay"),
        merchant("Zalando", .clothing, "zalando"),
        // Phone and travel providers
        merchant("Vodafone", .service, "vodafone"),
        merchant("Swisscom", .service, "swisscom"),
        merchant("SBB", .service, "sbb cff ffs", "sbb.ch"),
        // Manufacturers selling direct (last: their names appear on other shops' item lines)
        merchant("Apple", .electronics, "apple store", "apple.com", "apple distribution international"),
        merchant("Dyson", .appliance, "dyson.co.uk", "dyson.com", "dyson.ch", "dyson ltd"),
        merchant("Samsung", .electronics, "samsung.com", "samsung electronics"),
    ]

    /// One catalogue entry per key, all with the same name and category.
    private static func merchant(_ name: String, _ category: ProductCategory,
                                 _ keys: String...) -> [(key: String, name: String, category: ProductCategory)] {
        keys.map { (key: $0, name: name, category: category) }
    }

    // MARK: - Tables

    /// Postcode areas in Scotland (uppercase, the only list that is not folded).
    /// TD is left out because it crosses into England.
    static let scottishPostcodeAreas: [String] = [
        "AB", "DD", "DG", "EH", "FK", "G", "HS", "IV", "KA", "KW", "KY", "ML", "PA", "PH", "ZE",
    ]

    /// VAT rates in permille (81 = 8.1 %): UK 20/5; Switzerland 8.1/2.6/3.8 and,
    /// before 2024, 7.7/2.5/3.7; Germany 19/7; France 20/10/5.5/2.1; Italy 22/10/5;
    /// Ireland 23/13.5/9; Netherlands 21/9; Portugal 23/6.
    static let knownVATRatesPermille: [Int] = [
        200, 50, 81, 26, 38, 77, 25, 37, 190, 70, 100, 55, 210, 90, 220, 230, 135, 60, 21,
    ]
}
