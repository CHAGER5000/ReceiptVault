# ReceiptVault

*Working name. If it is taken on the App Store, the display name becomes
**Papertrail** (`INFOPLIST_KEY_CFBundleDisplayName`); the bundle ID
`com.chager5000.receiptvault` stays the same.*

A private, offline iPhone vault for the paperwork that protects your money:
receipts, invoices, warranty cards and contracts. Scan a receipt, pick photos,
or share a PDF from Mail, Files or SlimScan. The iPhone reads it (English,
German, French and Italian), saves it at once, and fills in the shop, date,
total, currency, VAT and products. ReceiptVault then works out the dates that
matter (return windows, the 14-day cancellation, the UK right to reject, the
EU/Swiss 2-year legal guarantee, the manufacturer warranty, and contract
notice deadlines) and reminds you a few days before each one.

**Nothing leaves the phone.** The app contains no networking code, no account,
no cloud, no analytics and no third-party SDKs. Documents are read and stored
only on the iPhone, encrypted while it is locked, behind Face ID. The App
Store privacy label is **Data Not Collected**. The only way anything leaves is
when you share a file yourself.

All legal dates are editable defaults. **They are general information, not
legal advice.**

## What it does

- **Capture**: scan with the document camera (several pages, edges
  straightened), pick up to 10 photos (they become the pages of one item),
  pick PDF, JPEG, PNG or HEIC files (one item per file), or use **Open in
  ReceiptVault** from the share sheet in SlimScan, Mail, Files or Safari.
- **Save first, check after**: the originals are stored and the item is
  created straight away. The review sheet opens next. Closing it keeps the
  item; **Discard** deletes it.
- **Reading on the phone**: PDF text is read exactly. Scans, photos and
  image-only PDFs are recognised by Apple's Vision. Each field has a
  confidence: it is filled at 0.5 or more and marked orange **Please check**
  below 0.75; otherwise it stays blank, because blank beats wrong. Items with a
  missing or unsure shop, date or total appear under **Needs a look**.
- **Pick from document**: tap any recognised line and choose *Use as total /
  VAT / date / delivery date / merchant / title / notes*.
- **Printed terms** (warranty length, return days, notice period, term and
  automatic renewal) override the defaults and are marked *From document*.
- **Duplicates**: every stored file's SHA-256 is recorded, and the review sheet
  says *Looks like a copy of … saved on …* with a **Discard this copy** button.
- **Key dates** for every item, with a basis and a certainty badge, and
  private reminders (see [Key dates and rules](#key-dates-and-rules)).
- **Contracts**: presets for Swiss insurance (VVG), Swiss basic health
  insurance (KVG), Swiss rentals, mobile and internet (CH and UK), monthly
  subscriptions, Germany after the minimum term, UK annual insurance and a
  custom contract. You get *Notice must arrive by*, *Send by*, *Mark notice
  sent* and a registered-post tip.
- **Upcoming**: what needs action, grouped as Overdue (last 30 days), Next 7
  days, Next 30 days and Later. Swipe to mark Done.
- **Library**: search by shop, product, any printed word, amount (`249`,
  `249.00`, `249,00`), amount range (`>500`, `<20`, `50-200`) or date
  (`2025-03-12`, `12.03.2025`, `march`, `märz`, `mars`, `marzo`). Case and
  accents are ignored, and Müller = Muller = Mueller.
- **Evidence PDF**: an A4 cover (details, amounts and VAT, key dates with
  certainty and status, the fault note, notes, and every original with its
  capture time, source and SHA-256 check), followed by every original page.
  Use it for a warranty, insurance or tax claim.
- **CSV export** of all items or only tax-claimable ones
  ([ReceiptVault CSV v1](#csv-export-receiptvault-csv-v1)).
- **Password-encrypted backup** (`.rvault`) that only you control
  ([format](#backup-file-format-rvault)).

## Privacy

- No networking code at all: no URL loading, no Network, WebKit,
  SafariServices, StoreKit or CloudKit, no Swift package dependencies. The
  Codemagic build fails if any of these, or a web address, appears in a Swift
  file under `ReceiptVault/`, or if a `Package.resolved` file exists.
- The SwiftData store is opened with `cloudKitDatabase: .none`.
- `PrivacyInfo.xcprivacy`: no tracking, no collected data, and the required
  reasons for UserDefaults (CA92.1) and file timestamps (C617.1).
- No Spotlight indexing, no widgets, no App Groups, no URL schemes, no Files
  app access to the vault folder, and document text is never logged.
- Reminders use private wording by default (*A deadline is coming up*), and
  amounts never appear in them, even with detailed wording on.

## Security

**Complete file protection.** The database, every stored original and
thumbnail, the staging folders and every export use iOS "complete" data
protection: they are encrypted with a key that exists only while the phone is
unlocked. The vault folder is stamped again at every launch. If iOS starts the
app in the background while the phone is locked, the database is not opened;
the app shows *Unlock your iPhone to open ReceiptVault* and opens it as soon as
the data becomes available. Changes are saved when the app goes inactive and
before the phone locks.

**The lock.** Face ID, Touch ID or the passcode opens the app (on by default,
Settings › Privacy). It locks whenever the app goes to the background, and a
cover hides the main screen in the app switcher. Turning the lock off,
restoring a backup and deleting all data each ask you to authenticate again.

**No passcode, no encryption.** Without a device passcode iOS has no key to
encrypt the vault with, and the lock has nothing to check. The app then shows
a permanent warning: *Set a passcode so iOS can encrypt your vault*.

**Files shared with "Open in".** iOS copies them into the app's
`Documents/Inbox`. ReceiptVault moves them into its protected
`Staging/Incoming` folder at once, even while the app is locked, and reads
them only after you unlock.

**Exports** (evidence PDFs, CSVs and `.rvault` files) are written to a
protected temporary folder and deleted when the share sheet closes, at launch,
and after an hour at the latest. Evidence PDFs and CSVs are deliberately not
encrypted, because they are meant for someone else; the share sheet shows
exactly what leaves the phone.

**Delete all data** removes every item and file, then deletes the database
files themselves before the next launch opens them, because SQLite can keep
deleted text in free pages.

### Backups: the trade-offs

| | Device backup (iCloud or computer) | Encrypted `.rvault` file |
|---|---|---|
| Default | Included | Made by you, from Settings › Backup |
| Who can read it | iCloud Backup is end-to-end encrypted only with **Advanced Data Protection**. An **unencrypted** Finder backup keeps app files readable on the computer. | Only someone with the password |
| Restores to | A phone restored from that backup | Any iPhone with ReceiptVault, merged into what is there |
| Turn off | Settings › Privacy › **Leave out of iCloud and computer backups** | Not needed |

- If you leave the vault out of device backups and never export a `.rvault`
  file, your receipts are lost with the phone. A reminder nudges you 30 days
  after your last encrypted backup.
- The backup password needs at least 10 characters and is typed twice. It is
  **never stored and cannot be recovered**: a lost password means a lost
  backup. Use a passphrase of four or more random words and save it in the
  iPhone Passwords app.
- A wrong password and a damaged file give the same message: *Wrong password
  or damaged file.*

## Key dates and rules

> General information, not legal advice. Dates come from the defaults in
> Settings › Rules and may not fit your case. Check the shop's terms and your
> contract.

This disclaimer appears on every screen and PDF that shows these dates.

**Start date.** Legal periods run from the delivery date when it is set,
otherwise from the purchase date. The in-store return window and the
manufacturer warranty run from the purchase date.

**Counting convention** (one rule everywhere, tested in `RVCalendar`):

- Day periods end on start + N days: 12 Mar 2024 + 28 days = **9 Apr 2024**.
- Month and year periods end the day before the anniversary: 12 Mar 2024 +
  6 months = **11 Sep 2024**. This errs early, so a date may be one day
  before the law's own end, never after it.

**Certainty badges.** Every date shows where it comes from:

| Badge | Meaning |
|---|---|
| **Law** | The built-in default follows the statute named in its basis |
| **Assumed** | A typical value or an interpretation, not certain |
| **From document** | Printed on the receipt, warranty card or contract |
| **You** | Entered on the item, or a rule you changed in Settings › Rules |

### The defaults

0 means "does not apply", shown as –. Every value can be changed in
**Settings › Rules and legal defaults**, and **Save and apply to existing
items** recalculates every item.

| Rule | England, Wales & NI | Scotland | Switzerland | EU |
|---|---|---|---|---|
| Shop return window (in store) | 28 days, Assumed (shop policy) | 28 days, Assumed | 14 days, Assumed (goodwill) | 14 days, Assumed |
| Online cancellation | 14 days, Law (Consumer Contracts Regulations 2013) | 14 days, Law | – (no statutory right) | 14 days, Law (Directive 2011/83/EU) |
| Doorstep or phone cancellation | 14 days, Law | 14 days, Law | 14 days, Assumed start (OR Art. 40a–40f) | 14 days, Law |
| Right to reject | 30 days, Law (CRA 2015 s.22) | 30 days, Law | – | – |
| Fault presumption | 6 months, Law (CRA s.19(14)–(15)) | 6 months, Law | – | 12 months, Assumed (Directive 2019/771 Art. 11 minimum) |
| Legal guarantee | – | – | 24 months, Law (OR Art. 210; may be limited under OR Art. 199) | 24 months, Law (Directive 2019/771 Art. 10 minimum) |
| Legal guarantee, used goods | – | – | 12 months, Assumed (by agreement) | 12 months, Assumed (Art. 10(6), by agreement) |
| Claim time limit | 6 years, Law (Limitation Act 1980; NI assumed the same) | 5 years, Assumed (Prescription and Limitation (Scotland) Act 1973, start simplified) | – | – |
| Manufacturer warranty | 12 months, Assumed | 12 months, Assumed | – (only if printed or entered) | 12 months, Assumed |

How the planner uses them:

- The manufacturer warranty default applies to electronics and appliances; for
  other goods only a printed or entered warranty counts.
- Groceries, services and "expense only" items get no goods dates, unless a
  return period or warranty is printed or entered.
- The default shop return window applies to in-store purchases; online and
  doorstep purchases get the 14-day cancellation instead, plus a return window
  only when one is printed or entered.
- The right to reject reminds only after you switch on **Something's wrong
  with it**. That switch also adds the Swiss note to report the defect
  promptly, in writing (OR Art. 201), and prints *Fault noticed on* in the
  evidence PDF.
- The fault presumption and the claim time limit appear on the timeline but
  do not remind.
- When the manufacturer warranty ends within 7 days of the legal guarantee,
  only the legal guarantee reminds.
- An optional minimum amount (off by default) silences reminders for small
  purchases, but never for contracts or warranty cards.

### Contracts

- **Notice must arrive by** = (term end + 1 day) − notice − 1 day. So 31 Dec
  with 3 months' notice gives **30 Sep**, 30 Jun gives **31 Mar**, 28 Feb with
  1 month gives **31 Jan**, and 31 Dec with 30 days gives **1 Dec**.
- Later terms are always counted from the first one, so month ends never
  drift: a monthly contract from 31 Jan ends 28 Feb, 31 Mar, 30 Apr. When a
  notice deadline has passed, the contract rolls forward to the next term and
  shows *Earlier notice dates have passed*.
- **Send by** = the arrive-by date minus the postal buffer (5 working days by
  default, Monday to Friday, no public-holiday tables). For Swiss basic health
  insurance, notice must arrive by 30 Nov 2026, so send by 23 Nov 2026. It is
  the day notice arrives that counts, so send it by registered post
  (Einschreiben / recommandé).
- Cancelled or non-renewing contracts get only *Contract ends*. A contract
  with no notice period (UK annual insurance) gets a *renews on* reminder so
  you can compare prices first.

### Reminders

| Date | Days before | Reminds by default |
|---|---|---|
| Shop return window, 14-day cancellation | 3, 1 | Yes |
| Right to reject | 5, 1 | Only with "Something's wrong with it" |
| Manufacturer warranty | 30, 7 | Yes |
| Legal guarantee | 30 | Yes |
| Notice deadline | 30, 14, 3 and the send-by day | Yes |
| Contract end | 30, 7 | Only when it is the contract's only date |
| Fault presumption | 30 | No |
| Claim time limit | 90 | No |
| Custom date | 7 | Yes |

- Reminders arrive at your chosen time (09:00 by default). Several for the
  same item on the same day are merged into one.
- They are planned again after every change and every time you open the app.
  Notification permission is asked the first time you save an item that has
  reminders, never at launch.
- Marking a date Done stops its reminders.

### Assumptions

These defaults are assumptions, and the app marks them *Assumed*. They should
be reviewed by a qualified person before release.

- **UK**: shop return windows (28 days) are goodwill policy, not law. Northern
  Ireland is assumed to match England and Wales (6-year claim limit). The start
  of the Scottish 5-year prescription is simplified to the delivery date.
- **Switzerland**: the 2-year guarantee (OR Art. 210, since 1 January 2013) is
  law, but sellers may limit or replace it in their terms (OR Art. 199), and
  defects must be reported promptly (OR Art. 201). The 1-year period for used
  goods by agreement, the start of the doorstep/phone 14-day period
  (OR Art. 40a–40f) and the typical 14-day shop goodwill are assumptions.
- **EU**: the 2-year guarantee (Directive 2019/771 Art. 10) and the 14-day
  withdrawal (Directive 2011/83/EU) are minimums. The 12-month fault
  presumption varies by country (24 months in France, for example), and the
  used-goods reduction depends on agreement.
- **Contracts**: the VVG Art. 35a exit after year 3 (assumed for contracts from
  before 2022 too); the KVG 30 November deadline and the 30 June switch with
  notice by 31 March for the standard model (check KVG Art. 7); German 1-month
  notice after the minimum term since March 2022; Swiss mobile 2 months; UK
  broadband and mobile 30 days; Swiss rental local dates; and that notice
  counts on arrival.
- **Counting**: month and year periods end the day before the anniversary,
  which may be one day earlier than the legal end.
- **Manufacturer warranties** of 12 months for electronics and appliances in
  the UK and EU are typical, not guaranteed.
- **Export compliance**: `ITSAppUsesNonExemptEncryption = false`, because the
  app only uses Apple's CryptoKit and CommonCrypto to protect your own data
  (see [Building on Codemagic](#building-on-codemagic)).
- **App Store**: the bundle ID and its App Store Connect record must exist
  before the first TestFlight build; the name "ReceiptVault" may be taken.
- **Reading**: Vision's accurate recogniser supports Italian on iOS 17.

## Backup file format (.rvault)

Everything needed to decrypt a backup without the app. All integers are
big-endian. The code is `ReceiptVault/Core/Backup.swift`.

**Header**, 32 bytes. Its bytes are part of every frame's authenticated data.

| Offset | Bytes | Content |
|---|---|---|
| 0 | 4 | Magic `RVLT` (`52 56 4C 54`) |
| 4 | 1 | Format version, `1` |
| 5 | 1 | Key derivation id, `1` = PBKDF2-HMAC-SHA256 then HKDF-SHA256 |
| 6 | 2 | Reserved, zero |
| 8 | 4 | PBKDF2 iterations, UInt32 (600,000) |
| 12 | 16 | Random salt |
| 28 | 4 | Reserved, zero |

**Key.**

1. `P` = the password in Unicode NFC, as UTF-8 (an accent typed composed or
   decomposed gives the same key).
2. `M` = PBKDF2-HMAC-SHA256(`P`, salt, iterations), 32 bytes (CommonCrypto).
3. `K` = HKDF-SHA256 (RFC 5869) with input key `M`, salt = the same salt,
   info = the ASCII text `ReceiptVault backup v1`, 32 bytes (CryptoKit).

**Frames** follow the header until the end of the file:

| Bytes | Content |
|---|---|
| 4 | Length `L` of what follows, UInt32, between 28 and 48 MiB + 28 |
| 12 | Random nonce |
| `L` − 28 | Ciphertext |
| 16 | GCM tag |

Each frame is one AES-256-GCM box under `K`. The authenticated data is the 32
header bytes followed by the frame's index as a UInt64 (the first frame is 0),
so a changed header, a swapped, dropped or reordered frame, or a wrong
password all fail the tag check.

**Entries.** The first byte of each decrypted frame is its type:

| Type | Body |
|---|---|
| `1` manifest | UTF-8 JSON. Always frame 0, and only there |
| `2` file | UInt16 name length `n`, `n` bytes of UTF-8 name, then the file's bytes |
| `3` end | UInt64: the number of frames before it. Must be the last frame, with nothing after it |

The order is manifest, one file entry per original, then the end frame, so a
truncated file or trailing data is detected. File names are `<UUID>.jpg` or
`<UUID>.pdf`, the originals' names in the vault. Thumbnails are not included;
the app rebuilds them.

**Manifest JSON** (keys sorted): `formatVersion` (1), `createdAt`,
`appVersion` and `items`. Each item holds the item's fields, its `deadlines`
and its `files` (`ItemDTO`, `DeadlineDTO` and `FileDTO` in `Backup.swift`):

| Kind of value | Encoding |
|---|---|
| Times (`createdAt`, `updatedAt`, `issueNotedAt`, `noticeSentAt`, `capturedAt`) | Seconds since 1 Jan 2001 00:00 UTC, a JSON number (add 978,307,200 for Unix time) |
| Calendar days (`purchaseDate`, `deliveryDate`, `termEnd`, a deadline's `date`) | `{"day": 12, "month": 3, "year": 2025}` |
| Amounts (`totalMinor`, `vatMinor`) | Integers in minor units: `24900` = 249.00 in `currency` |
| VAT rate (`vatRatePermille`) | Permille: `200` = 20 %, `81` = 8.1 % |
| `notice` | `{"unit": "months", "value": 3}`; the unit is `days`, `weeks` or `months` |
| `itemLines` | One product per line: name, tab, quantity, tab, amount in minor units (empty when unknown) |
| `checkFields` | Comma-separated names of fields still marked "Please check" |
| A file's `sha256` | Lowercase hex of the stored bytes, taken at capture |
| A file's `capturedTimeZone` | Time zone name, such as `Europe/London` |
| A deadline's `offsets` | Days before the date that remind |
| Ids | UUID strings |
| Optional values | Left out when not set |

Enums are stored as their raw strings:

- `kind`: `receipt`, `invoice`, `warranty`, `contract`
- `jurisdiction`: `englandWales`, `scotland`, `switzerland`, `eu`
- `channel`: `store`, `online`, `doorstep`
- `category`: `electronics`, `appliance`, `furniture`, `clothing`,
  `homeGarden`, `sportLeisure`, `vehicle`, `otherGoods`, `groceries`,
  `service`, `expense`
- `taxTag`: `none`, `uk`, `ch`, `both`
- a deadline's `kind`: `returnWindow`, `cancellation`, `rightToReject`,
  `faultPresumption`, `manufacturerWarranty`, `legalGuarantee`, `claimLimit`,
  `noticeDeadline`, `termEnd`, `custom`
- `certainty`: `law`, `assumption`, `printed`, `user`
- a file's `source`: `scan`, `photos`, `files`, `openIn`, `restored`

**What the app checks on restore.** The iteration count must be between
100,000 and 10,000,000 before any key is derived, and each frame length is
checked before anything is read. The manifest must come first, and file names
must match the `<UUID>.(jpg|pdf)` pattern exactly. Restored originals get new
local names, only item ids that are not already in the vault are added
(*Restored 42 items, 3 already present*), and each file keeps its capture-time
SHA-256, time, time zone and source.

### Decrypting without the app

Needs Python 3 and the `cryptography` package (`pip install cryptography`).
It writes `manifest.json` and every original into the output folder.

```python
#!/usr/bin/env python3
"""Decrypts a ReceiptVault backup: python3 rvault_decrypt.py Backup.rvault out/"""
import getpass, hashlib, os, re, struct, sys, unicodedata
from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

NAME = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.(jpg|pdf)")
MAX_FRAME = 48 * 1024 * 1024 + 28


def main(path, out):
    with open(path, "rb") as f:
        header = f.read(32)
        if len(header) != 32 or header[:4] != b"RVLT" or header[4] != 1 or header[5] != 1:
            sys.exit("Not a version 1 ReceiptVault backup.")
        iterations = struct.unpack(">I", header[8:12])[0]
        salt = header[12:28]
        if not 100_000 <= iterations <= 10_000_000:
            sys.exit("Unexpected iteration count.")
        password = unicodedata.normalize("NFC", getpass.getpass("Backup password: "))
        master = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations, 32)
        key = HKDF(algorithm=hashes.SHA256(), length=32, salt=salt,
                   info=b"ReceiptVault backup v1").derive(master)
        aes = AESGCM(key)
        os.makedirs(out, exist_ok=True)
        index = 0
        while True:
            prefix = f.read(4)
            if len(prefix) != 4:
                sys.exit("The file is incomplete: the end frame is missing.")
            length = struct.unpack(">I", prefix)[0]
            if not 28 <= length <= MAX_FRAME:
                sys.exit("Wrong password or damaged file.")
            sealed = f.read(length)
            if len(sealed) != length:
                sys.exit("The file is incomplete.")
            aad = header + struct.pack(">Q", index)
            try:
                plain = aes.decrypt(sealed[:12], sealed[12:], aad)
            except InvalidTag:
                sys.exit("Wrong password or damaged file.")
            kind, body = plain[:1], plain[1:]
            if index == 0:
                if kind != b"\x01":
                    sys.exit("The first entry is not the manifest.")
                with open(os.path.join(out, "manifest.json"), "wb") as m:
                    m.write(body)
            elif kind == b"\x02" and len(body) >= 2:
                n = struct.unpack(">H", body[:2])[0]
                name = body[2:2 + n].decode("utf-8", "replace")
                if len(body) < 2 + n or not NAME.fullmatch(name):
                    sys.exit("Unexpected file name.")
                with open(os.path.join(out, name), "wb") as o:
                    o.write(body[2 + n:])
            elif kind == b"\x03" and len(body) == 8:
                if struct.unpack(">Q", body)[0] != index or f.read(1):
                    sys.exit("Wrong password or damaged file.")
                print(f"Done: {index} entries written to {out}")
                return
            else:
                sys.exit("The backup contains an entry this script cannot read.")
            index += 1


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
```

To match the files to their items, look up each file name under `files` →
`fileName` in `manifest.json`.

## CSV export: 'ReceiptVault CSV v1'

Settings › Export writes `ReceiptVault-items.csv` (all items) or
`ReceiptVault-tax.csv` (only items tagged as tax-claimable). The file is UTF-8
with a header row, one line per item sorted by purchase date, and every line
ends with a line feed. The header is frozen: new columns will only ever be
added at the end.

| Column | Content |
|---|---|
| Date | Purchase date (the contract date for contracts), `yyyy-MM-dd` |
| Delivered | Delivery date, or empty |
| Merchant | Shop or company |
| Title | The item's title |
| Kind | `Receipt`, `Invoice`, `Warranty card` or `Contract` |
| Category | `Electronics`, `Appliances`, `Furniture`, `Clothing & shoes`, `Home & garden`, `Sport & leisure`, `Vehicles & parts`, `Other goods`, `Food & groceries`, `Service` or `Expense only (no dates)` |
| Total | Amount such as `1234.50` or `-12.30`: a dot for decimals, no thousands separators, no currency sign |
| Currency | ISO code: `GBP`, `CHF`, `EUR` or `USD` |
| VAT | VAT amount in the same form, or empty |
| VAT rate % | `20`, `8.1`, `2.6`, or empty |
| Claimable | Empty when not claimable, otherwise `UK`, `Switzerland` or `UK and Switzerland` (LocalLedger's labels) |
| Return by | The shop return window, otherwise the 14-day cancellation date |
| Warranty until | Manufacturer warranty end |
| Legal cover until | Legal guarantee end, otherwise the claim time limit |
| Notice by | Contract notice deadline |
| Notes | Your notes |
| ID | The item's UUID, the same as in a backup |

Escaping follows LocalLedger: a value containing a comma, a double quote or a
line break is put in double quotes, with quotes doubled. Example:

```
Date,Delivered,Merchant,Title,Kind,Category,Total,Currency,VAT,VAT rate %,Claimable,Return by,Warranty until,Legal cover until,Notice by,Notes,ID
2025-03-12,2025-03-14,Currys,HP Laptop 15,Invoice,Electronics,999.00,GBP,166.50,20,UK,2025-03-28,2026-03-11,2031-03-13,,"Work laptop, see invoice",3F2B8C1E-5D4A-4B7E-9C21-7A0D5E6F8B90
```

## Using it with SlimScan

The apps share nothing behind the scenes; files move only when you share or
save them.

**Keep a SlimScan scan in ReceiptVault**

1. Scan in SlimScan, tap **Share**, and choose **ReceiptVault** in the share
   sheet (under **More** if it is not in the first row).
2. ReceiptVault opens. If it is locked, the file is moved into its protected
   staging folder first and read after you unlock.
3. SlimScan PDFs contain images only, so the text is recognised with Vision
   (for long documents, the first 8 pages and the last 2). The review sheet
   opens as for any capture.

Or save the PDF in SlimScan (it appears in Files › On My iPhone › SlimScan)
and later choose **Add › Files** in ReceiptVault. Each file becomes one item.
ReceiptVault keeps PDFs byte for byte (up to 40 MB), so a small SlimScan PDF
stays small.

**Shrink an evidence PDF for email**

1. In ReceiptVault, open the item and tap **Prepare evidence PDF**.
2. Share it to **SlimScan**, shrink it there, then send it from SlimScan.

The fingerprints on the cover describe the originals kept in ReceiptVault,
not the shrunk PDF, so keep the vault copy as your evidence.

## Using it with LocalLedger

**Tax claims**

1. In ReceiptVault, set **Tax** on each claimable item to UK, Switzerland or
   both. These are LocalLedger's own tags and labels.
2. Settings › Export › **tax-claimable items as CSV**, and save it in Files
   next to LocalLedger's exports (LocalLedger › Tax › **Export year as CSV** or
   **Export claimable only**).
3. For each claim, **Prepare evidence PDF** and save it in the same folder.

The ReceiptVault export is not split into tax years yet (UK: 6 April to
5 April; Switzerland: the calendar year), so use the Date column.

**Coming in 1.1: find missing receipts.** ReceiptVault will read LocalLedger's
**Settings › Export all entries (CSV)** file (columns matched by header name)
and list bank entries without a receipt: the same currency, the same amount,
and a bank date from 3 days before to 7 days after the receipt. LocalLedger
needs no change for this. The *Claimable* column uses the same labels in
both apps, so LocalLedger can also read ReceiptVault's CSV later.

Code is shared by copying, not linking: the text layout, money and amount
parsing, the calendar convention, the document reader and scanner, the lock,
the storage pattern and the Codemagic pipeline all come from LocalLedger.

## Known limitations

- **Sheets are not covered in the app switcher.** The privacy cover hides the
  main screen only, so an open sheet (the review form, a QuickLook preview or
  a share sheet) can appear in the app-switcher snapshot. A shield window is
  planned.
- **Leaving the app locks it**, and unsaved edits in an open sheet are lost.
  Captured items are already saved, so only those edits are lost.
- **64 pending notifications.** iOS keeps at most 64 scheduled notifications,
  and ReceiptVault can only plan new ones when you open it. It schedules the
  59 soonest reminders, then one saying *Open ReceiptVault to keep your
  reminders up to date*, plus the backup reminder. If you have many dates and
  do not open the app for a long time, later reminders wait until you do.
- Tapping a notification opens the app, not the item (planned).
- *Send by* counts Monday to Friday and ignores public holidays.
- Duplicates are found by identical stored bytes: the same PDF shared twice
  is caught, a second scan of the same paper is not.
- Faded or crumpled thermal receipts may not be read; the fields are then left
  blank for you to fill in, and the original is always kept.
- Long scanned PDFs are read on their first 8 pages and last 2 only.
- No share extension: to save a picture from the Photos app, use **Add ›
  Photos** inside ReceiptVault.
- English interface and iPhone layout only.

## Building on Codemagic

`codemagic.yaml` has two workflows. Start either from the app's page on
Codemagic.

- **Tests and unsigned build** (`check`): needs no secrets. Run it first.
- **TestFlight** (`testflight`): signs the app and uploads it.

Both begin with the same three steps:

1. **No network code**: fails if a Swift file under `ReceiptVault/` mentions a
   network API, StoreKit, CloudKit or a web address, or if a
   `Package.resolved` file exists. Never write a web address in a Swift file,
   not even in a comment.
2. **Core tests (must pass)**: `DatesMoneyTests`, `RulesTests` and
   `BackupExportTests`.
3. **Extraction tests (report only)**: the receipt-reading fixtures are
   heuristic, so failures print a warning and do not stop the build.

`check` then builds without signing and lists the linked frameworks (a
warning only). `testflight` sets the build number from Codemagic's
`$BUILD_NUMBER`, creates the certificate and profile, builds the `.ipa` and
submits it to TestFlight.

### One-time setup

1. **Register the App ID.** In your Apple Developer account, under
   Certificates, Identifiers & Profiles › Identifiers, add an explicit App ID
   `com.chager5000.receiptvault`. No capabilities are needed: local
   notifications, Face ID and per-file data protection work without them.
2. **Create the App Store Connect record** (Apps › + › New App) with that
   bundle ID: name *ReceiptVault* (or *Papertrail* if it is taken), primary
   language English (UK), any SKU. The build creates the certificate and
   profile itself, but not the app record, and the upload fails without it.
3. **Add the `appstore` variable group** on the app's Environment variables
   tab in Codemagic, with each value marked *Secret*. It is the same group
   LocalLedger uses; if LocalLedger's group belongs to its own app page, add
   the same four variables here as well (or make it a team-wide group):
   - `APP_STORE_CONNECT_ISSUER_ID`: the Issuer ID from App Store Connect
   - `APP_STORE_CONNECT_KEY_IDENTIFIER`: the Key ID of an API key with the
     Admin role
   - `APP_STORE_CONNECT_PRIVATE_KEY`: the full text of its `AuthKey_XXXX.p8`
   - `CERTIFICATE_PRIVATE_KEY`: an RSA key for the signing certificate, made
     with `ssh-keygen -t rsa -b 2048 -m PEM -f cert_key -q -N ""`
4. **Answer the export-compliance questions.** `Config/Info.plist` sets
   `ITSAppUsesNonExemptEncryption` to `false`, so builds are not held for the
   encryption question. This is an **assumption**: the app only uses Apple's
   CryptoKit and CommonCrypto to protect your own backups. Confirm it in App
   Store Connect before the first TestFlight upload, including the separate
   question about France. If your answers differ, change the key and provide
   what App Store Connect asks for.
5. **App Store details.** App Privacy: *Data Not Collected*. App Store
   Connect still asks for a privacy policy web address; a short page that
   repeats the privacy statement above will do. Price: paid up front (about
   £3.99 / CHF 4.00 / €3.99), no in-app purchases, Family Sharing on.

Much of the code was written without a compiler at hand, so run the `check`
workflow first and expect one round of fixes.

### Tests and Xcode on a Mac

`ReceiptVault/Core` is plain Foundation code (plus CryptoKit and CommonCrypto),
also built as the `ReceiptCore` Swift package:

```bash
swift test                                                                              # everything
swift test --filter 'ReceiptCoreTests\.(DatesMoneyTests|RulesTests|BackupExportTests)'  # must pass
```

To run the app: open `ReceiptVault.xcodeproj` in Xcode 16 or newer (Codemagic
uses the latest), choose your Team under **Signing & Capabilities**, and press
Run on an iPhone with iOS 17 or later. The document camera needs a real
device. Every file under `ReceiptVault/` is compiled into the app through the
synchronised folder, so new files need no project changes.

## Project layout

```
ReceiptVault/
  App/        App entry, VaultStore and Storage, Face ID lock (LockGate,
              OwnerCheck), protected file storage (FileVault),
              notifications, evidence PDF, CSV and backup export/restore
  Capture/    Document camera, PDF and Vision text reading, capture pipeline
  Core/       Plain Foundation code, also the ReceiptCore package tested with
              `swift test`: dates, money, text layout, keyword lists,
              receipt reading, printed terms, rules and legal notes,
              contract maths, reminder planning, backup format, search,
              CSV and evidence text
  Models/     SwiftData models and RecordService (every database change)
  Views/      Upcoming, Library, item detail and edit, Settings, rules
              editor, backup and restore sheets
  Resources/  PrivacyInfo.xcprivacy
Config/       Info.plist: document types (PDF, images, .rvault) and export
              compliance
Tests/        ReceiptCoreTests: must-pass tests and extraction fixtures
tools/        make_icon.py (draws the app icon)
```
