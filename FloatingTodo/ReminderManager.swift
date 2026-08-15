import EventKit
import Foundation
import UserNotifications

struct ReminderScheduleResult {
    let provider: TodoReminderProvider
    let eventKitIdentifier: String?
}

struct ReminderExternalState {
    let title: String
    let note: String
    let dueDate: Date?
    let completed: Bool
}

enum ReminderManagerError: LocalizedError {
    case notificationPermissionDenied
    case reminderCalendarUnavailable

    var errorDescription: String? {
        switch self {
        case .notificationPermissionDenied:
            return "Apple 提醒事项和 Sticky 通知权限均不可用"
        case .reminderCalendarUnavailable:
            return "无法找到可写入的 Apple 提醒事项列表"
        }
    }
}

final class ReminderManager {
    private let eventStore = EKEventStore()
    private let notificationCenter = UNUserNotificationCenter.current()
    private let calendarTitle = "Sticky"

    func schedule(item: TodoItem, pageTitle: String, at date: Date) async throws -> ReminderScheduleResult {
        if await canUseAppleReminders() {
            do {
                let identifier = try saveAppleReminder(item: item, pageTitle: pageTitle, at: date)
                cancelLocalNotification(for: item.id)
                return ReminderScheduleResult(provider: .appleReminders, eventKitIdentifier: identifier)
            } catch {
                // Apple 提醒事项暂时无法写入时，仍保证这条事项可以按时提醒。
                print("Failed to save Apple reminder, using local notification: \(error)")
            }
        }

        try await scheduleLocalNotification(item: item, pageTitle: pageTitle, at: date)
        return ReminderScheduleResult(provider: .localNotification, eventKitIdentifier: nil)
    }

    func update(item: TodoItem, pageTitle: String) async {
        guard let date = item.reminderDate else { return }

        switch item.reminderProvider {
        case .appleReminders:
            guard remindersAreAuthorized else { return }
            do {
                _ = try saveAppleReminder(item: item, pageTitle: pageTitle, at: date)
            } catch {
                print("Failed to update Apple reminder: \(error)")
            }
        case .localNotification:
            cancelLocalNotification(for: item.id)
            guard !item.completed, date > Date() else { return }
            do {
                try await scheduleLocalNotification(item: item, pageTitle: pageTitle, at: date)
            } catch {
                print("Failed to update local notification: \(error)")
            }
        case .none:
            break
        }
    }

    func remove(item: TodoItem) {
        cancelLocalNotification(for: item.id)

        guard item.reminderProvider == .appleReminders,
              remindersAreAuthorized,
              let identifier = item.eventKitIdentifier,
              let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else { return }

        do {
            try eventStore.remove(reminder, commit: true)
        } catch {
            print("Failed to remove Apple reminder: \(error)")
        }
    }

    func externalState(identifier: String) -> ReminderExternalState? {
        guard remindersAreAuthorized,
              let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else { return nil }

        let dueDate = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        let rawNote = reminder.notes ?? ""
        let userNote: String
        if rawNote.hasPrefix("来自 Sticky ·") {
            userNote = ""
        } else {
            userNote = rawNote.components(separatedBy: "\n\n来自 Sticky ·").first ?? rawNote
        }

        return ReminderExternalState(
            title: reminder.title ?? "",
            note: userNote,
            dueDate: dueDate,
            completed: reminder.isCompleted
        )
    }

    private var remindersAreAuthorized: Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized:
            return true
        default:
            return false
        }
    }

    private func canUseAppleReminders() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized:
            return true
        case .notDetermined:
            do {
                return try await eventStore.requestFullAccessToReminders()
            } catch {
                print("Apple Reminders authorization failed: \(error)")
                return false
            }
        case .denied, .restricted, .writeOnly:
            return false
        @unknown default:
            return false
        }
    }

    private func saveAppleReminder(item: TodoItem, pageTitle: String, at date: Date) throws -> String {
        let reminder: EKReminder
        if let identifier = item.eventKitIdentifier,
           let existing = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder {
            reminder = existing
        } else {
            reminder = EKReminder(eventStore: eventStore)
            reminder.calendar = try reminderCalendar()
        }

        reminder.title = item.text
        reminder.notes = item.note.isEmpty ? "来自 Sticky · \(pageTitle)" : "\(item.note)\n\n来自 Sticky · \(pageTitle)"
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
            from: date
        )
        reminder.alarms = [EKAlarm(absoluteDate: date)]
        reminder.isCompleted = item.completed
        try eventStore.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    private func reminderCalendar() throws -> EKCalendar {
        if let existing = eventStore.calendars(for: .reminder).first(where: { $0.title == calendarTitle }) {
            return existing
        }

        guard let source = eventStore.defaultCalendarForNewReminders()?.source else {
            throw ReminderManagerError.reminderCalendarUnavailable
        }

        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        calendar.title = calendarTitle
        calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
        return calendar
    }

    private func scheduleLocalNotification(item: TodoItem, pageTitle: String, at date: Date) async throws {
        let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
        guard granted else { throw ReminderManagerError.notificationPermissionDenied }

        let content = UNMutableNotificationContent()
        content.title = item.text
        content.body = "Sticky · \(pageTitle)"
        content.sound = .default

        let dateComponents = Calendar.current.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
            from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        let request = UNNotificationRequest(
            identifier: notificationIdentifier(for: item.id),
            content: content,
            trigger: trigger
        )
        try await notificationCenter.add(request)
    }

    private func cancelLocalNotification(for itemId: UUID) {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [notificationIdentifier(for: itemId)])
    }

    private func notificationIdentifier(for itemId: UUID) -> String {
        "sticky.reminder.\(itemId.uuidString)"
    }
}
