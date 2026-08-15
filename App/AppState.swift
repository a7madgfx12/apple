import Foundation
import Combine
import UserNotifications

/// Composition root: builds and holds every service as a single source of truth,
/// injected into the SwiftUI environment from `PrayerCompanionApp`.
@MainActor
final class AppState: NSObject, ObservableObject {
    let settings: SettingsStore
    let locationService: LocationServicing
    let permissionManager: PermissionManager
    let scheduleService: PrayerScheduleService
    let audioManager: PrayerAudioManager
    let notificationManager: NotificationManager
    let cameraService: CameraService
    let recognitionService: PrayerMatRecognitionService
    let azkarService: AzkarService

    @Published var activeAlarm: ActivePrayerAlarm?
    @Published var route: Route = .home

    /// Alarms already verified-complete today, so the 1-second watcher doesn't immediately
    /// re-trigger the very same prayer the instant `activeAlarm` is cleared (it would
    /// otherwise still see "now is within the alarm's 10-minute window" and fire again).
    /// Keyed by prayer + alarm timestamp, so it naturally stops matching once tomorrow's
    /// schedule produces a new alarm time for that prayer.
    private var completedAlarmIdentifiers: Set<String> = []

    enum Route: Hashable { case home, azkar, settings }

    override init() {
        let settings = SettingsStore()
        let location = LocationService()
        self.settings = settings
        self.locationService = location
        self.permissionManager = PermissionManager(locationService: location)
        self.notificationManager = NotificationManager()
        self.scheduleService = PrayerScheduleService(locationService: location, settings: settings, notificationManager: notificationManager)
        self.audioManager = PrayerAudioManager(settings: settings)
        self.cameraService = CameraService()
        self.recognitionService = PrayerMatRecognitionService()
        self.azkarService = AzkarService()
        super.init()

        AppServiceLocator.azkarService = azkarService
        notificationManager.registerCategories()
        UNUserNotificationCenter.current().delegate = self
        Task { await scheduleService.refresh() }
        scheduleAlarmWatcher()
    }

    /// Polls the current schedule once a second for prayers reaching their alarm time.
    /// (A lightweight in-app timer; system-level firing/awareness is additionally handled
    /// by NotificationManager's scheduled local notifications.)
    private var watcherTimer: Timer?
    private func scheduleAlarmWatcher() {
        watcherTimer?.invalidate()
        watcherTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForDueAlarm() }
        }
    }

    private func checkForDueAlarm() {
        guard activeAlarm == nil, let schedule = scheduleService.todaySchedule else { return }
        let now = Date()
        for entry in schedule.entries where settings.isPrayerEnabled(entry.prayer) {
            guard !completedAlarmIdentifiers.contains(identifier(for: entry)) else { continue }
            if now >= entry.alarmTime && now < entry.alarmTime.addingTimeInterval(600) {
                trigger(entry: entry)
                break
            }
        }
    }

    private func identifier(for entry: PrayerTimeEntry) -> String {
        "\(entry.prayer.rawValue)-\(Int(entry.alarmTime.timeIntervalSince1970))"
    }

    private func trigger(entry: PrayerTimeEntry) {
        let sourceDescription = settings.audioSourceKind == .custom
            ? (settings.customAudioDisplayName ?? "نغمة مخصصة")
            : "الأذان الافتراضي"
        let alarm = ActivePrayerAlarm(prayer: entry.prayer, prayerTime: entry.time, alarmStartTime: Date(), audioSourceDescription: sourceDescription, status: .active)
        activeAlarm = alarm
        try? audioManager.start(for: alarm)
    }

    /// Called only after successful on-device prayer-mat verification.
    func markPrayerCompleted() {
        if let alarm = activeAlarm, let schedule = scheduleService.todaySchedule, let entry = schedule.entry(for: alarm.prayer) {
            completedAlarmIdentifiers.insert(identifier(for: entry))
        }
        audioManager.stopAfterVerification()
        activeAlarm = nil
    }

    /// Manually fires the exact same alarm flow (audio + full-screen alert + camera
    /// verification) right now, for testing the configured sound and verification flow
    /// without waiting for an actual prayer time. Uses the next enabled prayer if one
    /// exists in today's schedule, otherwise a synthetic "الظهر" entry for "right now".
    func triggerTestAlarm() {
        guard activeAlarm == nil else { return }
        let now = Date()
        let entry: PrayerTimeEntry
        if let schedule = scheduleService.todaySchedule,
           let next = schedule.entries.first(where: { settings.isPrayerEnabled($0.prayer) }) {
            entry = PrayerTimeEntry(prayer: next.prayer, time: now.addingTimeInterval(-15 * 60))
        } else {
            entry = PrayerTimeEntry(prayer: .dhuhr, time: now.addingTimeInterval(-15 * 60))
        }
        trigger(entry: entry)
    }
}

extension AppState: @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["prayer"] as? String, let prayer = Prayer(rawValue: raw) else { return }
        // The "wudu" heads-up (fired at raw prayer time) is informational only — it must never
        // itself start the audio alarm. Only the "alarm" notification (fired at time + 15 min)
        // does, and only once that alarm time has actually arrived.
        guard response.notification.request.content.userInfo["kind"] as? String == "alarm" else { return }
        guard let schedule = scheduleService.todaySchedule, let entry = schedule.entry(for: prayer) else { return }
        guard Date() >= entry.alarmTime else { return }
        guard !completedAlarmIdentifiers.contains(identifier(for: entry)) else { return }
        if activeAlarm == nil {
            trigger(entry: entry)
        }
    }
}
