import Foundation
import ActivityKit

/// Live Activity поїздки: запускається разом із записом, оновлюється з кожним
/// рядком CSV і завершується з підсумком. Без неї запис працює так само, тому
/// всі помилки ActivityKit тихо ігноруються.
final class LiveActivityController {
    private var activity: Activity<VeloxTripAttributes>?
    private var lastState: VeloxTripAttributes.ContentState?
    private var lastUpdate = Date.distantPast

    // Швидкість змінюється постійно, а iOS однаково обмежує частоту оновлень:
    // другорядні зміни відправляються не частіше, ніж раз на стільки секунд
    private static let minUpdateInterval: TimeInterval = 2.0
    // Скільки підсумок поїздки лишається на заблокованому екрані
    private static let summaryLifetime: TimeInterval = 15 * 60

    /// Користувач не вимкнув Live Activities для Velox у налаштуваннях iOS
    var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(startedAt: Date, state: VeloxTripAttributes.ContentState) {
        guard activity == nil, isAvailable else { return }
        do {
            activity = try Activity.request(attributes: VeloxTripAttributes(startedAt: startedAt),
                                            content: ActivityContent(state: state, staleDate: nil),
                                            pushType: nil)
            lastState = state
            lastUpdate = Date()
        } catch {
            activity = nil
        }
    }

    func update(_ state: VeloxTripAttributes.ContentState) {
        guard let activity = activity, state != lastState else { return }
        // Подія (штраф, зміна стану) - одразу; лише швидкість - не частіше за minUpdateInterval
        let important = state.score != lastState?.score
            || state.status != lastState?.status
            || state.maneuvers != lastState?.maneuvers
            || state.distractions != lastState?.distractions
        guard important || Date().timeIntervalSince(lastUpdate) >= Self.minUpdateInterval else { return }
        lastState = state
        lastUpdate = Date()
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func end(state: VeloxTripAttributes.ContentState) {
        guard let activity = activity else { return }
        self.activity = nil
        lastState = nil
        let dismissAt = Date().addingTimeInterval(Self.summaryLifetime)
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(dismissAt))
        }
    }

    /// Активності, що лишились після аварійного завершення застосунку посеред поїздки
    static func endStale() {
        for activity in Activity<VeloxTripAttributes>.activities {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}

extension SafetyClass {
    var liveActivityLevel: VeloxTripAttributes.Level {
        switch self {
        case .safe: return .safe
        case .medium: return .medium
        case .dangerous: return .danger
        }
    }
}
