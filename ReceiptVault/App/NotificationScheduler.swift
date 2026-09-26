import Foundation
import SwiftData
import UserNotifications

/// The app's only UserNotifications code. ReminderPlanner decides what fires
/// and when; this turns the plan into pending local notifications.
/// No delegate, no actions, no background work. userInfo holds only
/// 'itemID', and amounts never appear in the text.
@MainActor
enum NotificationScheduler {
    /// Bumped by every replan and removeAll, so a run that has been overtaken
    /// stops at its next suspension point instead of adding an older plan.
    private static var generation = 0

    // MARK: Permission

    /// Asks for permission the first time (never at launch; callers do this
    /// when the first item with reminders is created). True when reminders
    /// can be delivered.
    static func requestIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            return granted
        default:
            return NotificationScheduler.canSchedule(settings.authorizationStatus)
        }
    }

    /// True when the user has turned notifications off for the app in
    /// Settings, so the app can say reminders will not arrive.
    static func isDenied() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .denied
    }

    // MARK: Scheduling

    /// Replaces every pending 'rv.' request with the current plan: the
    /// reminded deadlines plus the backup nudge. Requests are added only when
    /// notifications are allowed. Running it twice changes nothing.
    static func replan(context: ModelContext) async {
        generation &+= 1
        let run = generation
        // Read the store before the first suspension, so the plan matches
        // the data as it is now.
        let plan = NotificationScheduler.plan(context: context, now: Date())

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard run == generation else { return }
        let allowed = NotificationScheduler.canSchedule(settings.authorizationStatus)
        let wanted: Set<String> = allowed ? Set(plan.map { $0.identifier }) : []

        // Remove what is no longer planned first, so the old and new sets
        // together never push past iOS's 64 pending requests. A planned
        // identifier that is still pending is replaced by the add below.
        let pending = await center.pendingNotificationRequests()
        guard run == generation else { return }
        let stale = pending
            .map { $0.identifier }
            .filter { $0.hasPrefix(ReminderPlanner.prefix) && !wanted.contains($0) }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }

        guard allowed else { return }
        for reminder in plan {
            guard run == generation else { return }
            try? await center.add(NotificationScheduler.request(for: reminder))
        }
    }

    /// Removes every pending and delivered ReceiptVault notification, and
    /// stops a replan that is still running.
    static func removeAll() async {
        generation &+= 1
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    // MARK: Helpers

    /// The deadline reminders at the user's time, plus 'rv.backup'. The
    /// backup nudge is left out while the vault is empty.
    private static func plan(context: ModelContext, now: Date) -> [PlannedReminder] {
        let today = RVCalendar.today(now: now)
        let clock = Calendar.current.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (clock.hour ?? 0) * 60 + (clock.minute ?? 0)
        let hour = AppSettings.reminderHour
        let minute = AppSettings.reminderMinute

        var plan = ReminderPlanner.plan(RecordService.reminderInputs(context: context),
                                        today: today,
                                        nowMinutes: nowMinutes,
                                        hour: hour,
                                        minute: minute,
                                        privateText: AppSettings.privateReminderText)

        let itemCount = (try? context.fetchCount(FetchDescriptor<VaultItem>())) ?? 0
        if itemCount > 0 {
            // The backup's day on the user's own calendar.
            let lastBackup = AppSettings.lastBackupAt.map { RVCalendar.today(now: $0) }
            if let backup = ReminderPlanner.backupReminder(lastBackup: lastBackup,
                                                           everyDays: AppSettings.backupReminderDays,
                                                           today: today,
                                                           nowMinutes: nowMinutes,
                                                           hour: hour,
                                                           minute: minute) {
                plan.append(backup)
            }
        }
        return plan
    }

    /// One non-repeating request at the reminder's local wall-clock time. The
    /// stored day is converted by year, month and day only, with no time zone,
    /// so the time stays local when the user travels.
    private static func request(for reminder: PlannedReminder) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        if !reminder.itemID.isEmpty {
            content.userInfo = ["itemID": reminder.itemID]
        }

        // The components are Gregorian; say so only when the user's calendar
        // is not (Buddhist, Japanese, ...), where the year would read differently.
        let calendar: Calendar? = Calendar.current.identifier == .gregorian ? nil : Calendar(identifier: .gregorian)
        let when = DateComponents(calendar: calendar,
                                  year: reminder.fireDay.year,
                                  month: reminder.fireDay.month,
                                  day: reminder.fireDay.day,
                                  hour: reminder.hour,
                                  minute: reminder.minute)
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
        return UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger)
    }

    /// Authorised, provisional (quiet delivery) or ephemeral.
    private static func canSchedule(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }
}
