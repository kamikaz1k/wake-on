import AlarmKit
import SwiftUI

/// What Pixie attaches to each alarm or timer it schedules with AlarmKit; the Live Activity
/// extension reads it to show the label on the lock screen and in the Dynamic Island.
@available(iOS 26.0, *)
struct PixieAlarmMetadata: AlarmMetadata {
    var label: String = ""
    var timer = false
}

enum PixieAlarmStyle {
    static let tint = Color(red: 0.35, green: 0.65, blue: 1.0)
}
