// swift-tools-version:5.9
// The receipt-reading and reminder logic (ReceiptVault/Core) is plain Foundation
// code, so it is also built as a package and tested with `swift test` on a Mac.
// The app compiles the same files directly through its synchronised folder, so
// Xcode has no package dependency. No third-party dependencies.
import PackageDescription

let package = Package(
    name: "ReceiptCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    targets: [
        .target(name: "ReceiptCore", path: "ReceiptVault/Core"),
        .testTarget(name: "ReceiptCoreTests", dependencies: ["ReceiptCore"], path: "Tests/ReceiptCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
