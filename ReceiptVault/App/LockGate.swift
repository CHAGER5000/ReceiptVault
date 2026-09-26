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
    /// True at launch and after the app has been in the background, until the
    /// scene is next active or a prompt starts. The Face ID / passcode prompt itself makes the
    /// scene inactive and then active again, so asking on every return to
    /// active would show a cancelled prompt again and again.
    @State private var askWhenActive = true
    /// Counts the trips to the background. A prompt that succeeds only after
    /// the app has gone to the background again does not unlock the new session.
    @State private var lockEpoch = 0

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
            if phase == .background {
                unlocked = false
                askWhenActive = true
                lockEpoch += 1
            }
            if phase == .active {
                let ask = askWhenActive
                askWhenActive = false
                if !lockEnabled {
                    // The gate stays open while the lock is off, so turning
                    // the lock on in Settings does not lock the screen at once
                    // (it locks at the next background).
                    unlocked = true
                } else if ask && !unlocked {
                    authenticate()
                }
            }
        }
        .onAppear {
            if !lockEnabled {
                unlocked = true
            } else if scenePhase == .active && !unlocked {
                authenticate()
            }
            // Otherwise the scene is not active yet: the prompt is shown when
            // it becomes active (askWhenActive is still true).
        }
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
        // A prompt is starting now, so the return to active that follows it
        // (after a success or a cancel) must not ask again.
        askWhenActive = false
        let context = LAContext()
        var error: NSError?
        // No passcode set on the phone: nothing to check against.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            unlocked = true
            return
        }
        authenticating = true
        let epoch: Int = lockEpoch
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your receipts") { success, _ in
            DispatchQueue.main.async {
                authenticating = false
                // A success that arrives after the app went to the background
                // again belongs to the old session, so the gate stays locked.
                if success && epoch == lockEpoch { unlocked = true }
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
