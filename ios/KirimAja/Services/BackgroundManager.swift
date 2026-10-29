import Foundation
import UIKit
import BackgroundTasks
import UserNotifications

/// Manages iOS background execution to prevent transfers from dropping when the screen is locked
/// or the user switches apps. Implements PRD Section 3.7 strategy.
public class BackgroundManager: ObservableObject {
    public static let shared = BackgroundManager()

    public static let backgroundTaskId = "com.kirimaja.transfer.process"
    
    private var bgTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
    @Published public var keepScreenOn: Bool = true {
        didSet {
            updateIdleTimer()
        }
    }

    private init() {
        requestNotificationPermission()
    }

    /// Registers the background processing task with the iOS system.
    /// Call this from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
    public func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskId,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            self.handleProcessingTask(processingTask)
        }
    }

    /// Enables or disables screen dimming / sleep timer based on user preference and active transfer.
    public func updateIdleTimer(isTransferring: Bool = false) {
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = isTransferring && self.keepScreenOn
        }
    }

    /// Begins a short-term iOS background task (~30s to several minutes) when transfer starts.
    public func beginTransferBackgroundTask(description: String = "KirimAja File Transfer") {
        guard bgTaskIdentifier == .invalid else { return }
        
        bgTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: description) { [weak self] in
            guard let self = self else { return }
            self.endTransferBackgroundTask()
            self.scheduleProcessingTask()
            self.sendNotification(
                title: "Transfer dijeda oleh sistem",
                body: "Buka kembali KirimAja untuk melanjutkan transfer secara otomatis."
            )
        }
    }

    /// Ends the short-term iOS background task.
    public func endTransferBackgroundTask() {
        if bgTaskIdentifier != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskIdentifier)
            bgTaskIdentifier = .invalid
        }
        updateIdleTimer(isTransferring: false)
    }

    /// Schedules a BGProcessingTask for longer background execution (e.g. while charging).
    public func scheduleProcessingTask() {
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskId)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 1)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Could not schedule background processing task: \(error.localizedDescription)")
        }
    }

    private func handleProcessingTask(_ task: BGProcessingTask) {
        scheduleProcessingTask()

        task.expirationHandler = {
            self.sendNotification(
                title: "Transfer tertahan",
                body: "Buka kembali aplikasi untuk melanjutkan sisa transfer file."
            )
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    public func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}
