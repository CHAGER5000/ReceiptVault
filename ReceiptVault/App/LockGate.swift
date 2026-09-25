import SwiftUI
import LocalAuthentication

/// Asks for Face ID / Touch ID / passcode when the app opens or comes back
/// from the background, and hides the content in the app switcher.
struct LockGate<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @AppStorage(SettingsKeys.lockEnabled) private var lockEnabled = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var unlocked = false
    @State private var authenticating = false

    var body: some View {
        ZStack {
            if unlocked || !lockEnabled {
                content()
            } else {
                lockedView
            }
            if scenePhase != .active {
                privacyCover
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { unlocked = false }
            if phase == .active && !unlocked && lockEnabled { authenticate() }
        }
        .onAppear { if lockEnabled { authenticate() } }
    }

    private var lockedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("ReceiptVault is locked").font(.headline)
            Button("Unlock") { authenticate() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var privacyCover: some View {
        ZStack {
            Color(.systemBackground)
            Image(systemName: "lock.shield").font(.system(size: 44)).foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
    }

    private func authenticate() {
        guard !authenticating else { return }
        let context = LAContext()
        var error: NSError?
        // No passcode set on the phone: nothing to check against.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            unlocked = true
            return
        }
        authenticating = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your receipts") { success, _ in
            DispatchQueue.main.async {
                authenticating = false
                if success { unlocked = true }
            }
        }
    }
}

/// Re-authenticates the owner before sensitive actions (turning the lock off,
/// restoring a backup, deleting all data), and reports whether a passcode is set.
enum OwnerCheck {
    /// Whether the phone has a passcode (and so Face ID / Touch ID can be used).
    /// Without one, iOS cannot encrypt the vault and the lock unlocks silently.
    static func deviceHasPasscode() -> Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Asks for Face ID / Touch ID / passcode with the given reason.
    /// Returns true when there is no passcode on the phone (nothing to check against).
    @MainActor static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return true
        }
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
                continuation.resume(returning: ok)
            }
        }
        // Keeps the context alive until the evaluation has finished.
        context.invalidate()
        return success
    }
}
