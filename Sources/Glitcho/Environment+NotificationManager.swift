import SwiftUI

private struct NotificationManagerKey: EnvironmentKey {
    static let defaultValue: NotificationManager? = nil
}

extension EnvironmentValues {
    var notificationManager: NotificationManager? {
        get { self[NotificationManagerKey.self] }
        set { self[NotificationManagerKey.self] = newValue }
    }
}
