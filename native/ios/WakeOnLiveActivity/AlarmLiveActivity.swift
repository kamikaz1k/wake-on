import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

/// Pixie's alarms and timers on the lock screen and in the Dynamic Island: the label and a
/// countdown while a timer (or a snooze) runs. The ringing alert itself is iOS's own.
@available(iOS 26.0, *)
struct AlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<PixieAlarmMetadata>.self) { context in
            HStack(spacing: 14) {
                Image(systemName: symbol(context)).font(.title).foregroundStyle(PixieAlarmStyle.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(context)).font(.headline)
                    Text(status(context)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                remaining(context).font(.system(size: 40, weight: .semibold)).monospacedDigit()
                    .multilineTextAlignment(.trailing)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(title(context), systemImage: symbol(context)).font(.headline).foregroundStyle(PixieAlarmStyle.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    remaining(context).font(.title2.weight(.semibold)).monospacedDigit()
                }
            } compactLeading: {
                Image(systemName: symbol(context)).foregroundStyle(PixieAlarmStyle.tint)
            } compactTrailing: {
                remaining(context).monospacedDigit().frame(maxWidth: 56)
            } minimal: {
                Image(systemName: symbol(context)).foregroundStyle(PixieAlarmStyle.tint)
            }
            .keylineTint(PixieAlarmStyle.tint)
        }
    }

    private func title(_ context: ActivityViewContext<AlarmAttributes<PixieAlarmMetadata>>) -> String {
        let label = context.attributes.metadata?.label ?? ""
        if !label.isEmpty { return label }
        return context.attributes.metadata?.timer == true ? "Timer" : "Alarm"
    }

    private func symbol(_ context: ActivityViewContext<AlarmAttributes<PixieAlarmMetadata>>) -> String {
        context.attributes.metadata?.timer == true ? "timer" : "alarm.fill"
    }

    private func status(_ context: ActivityViewContext<AlarmAttributes<PixieAlarmMetadata>>) -> String {
        switch context.state.mode {
        case .countdown: return context.attributes.metadata?.timer == true ? "Timer" : "Snoozing"
        case .paused: return "Paused"
        case .alert: return "Ringing"
        @unknown default: return ""
        }
    }

    @ViewBuilder
    private func remaining(_ context: ActivityViewContext<AlarmAttributes<PixieAlarmMetadata>>) -> some View {
        switch context.state.mode {
        case .countdown(let countdown):
            Text(timerInterval: Date.now...max(Date.now, countdown.fireDate), countsDown: true)
        case .paused(let paused):
            let left = max(0, paused.totalCountdownDuration - paused.previouslyElapsedDuration)
            Text(Duration.seconds(left).formatted(.time(pattern: left >= 3600 ? .hourMinuteSecond : .minuteSecond)))
        case .alert:
            Image(systemName: "bell.and.waves.left.and.right.fill")
        @unknown default:
            EmptyView()
        }
    }
}
