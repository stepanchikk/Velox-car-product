import SwiftUI

// Класифікація підсумкової оцінки Safety Score.
// Межі задано у VeloxConfig: 90-100 безпечно, 75-89 середньо, менше 75 небезпечно.
nonisolated enum SafetyClass {
    case safe
    case medium
    case dangerous

    static func classify(_ score: Int) -> SafetyClass {
        switch score {
        case VeloxConfig.safeScoreMin...:
            return .safe
        case VeloxConfig.mediumScoreMin..<VeloxConfig.safeScoreMin:
            return .medium
        default:
            return .dangerous
        }
    }

    var label: String {
        switch self {
        case .safe: return "Безпечний водій"
        case .medium: return "Середній рівень"
        case .dangerous: return "Небезпечне керування"
        }
    }

    var emoji: String {
        switch self {
        case .safe: return "\u{1F7E2}"       // 🟢
        case .medium: return "\u{1F7E1}"     // 🟡
        case .dangerous: return "\u{1F534}"  // 🔴
        }
    }

    var color: Color {
        switch self {
        case .safe: return VeloxColor.safe
        case .medium: return VeloxColor.medium
        case .dangerous: return VeloxColor.danger
        }
    }
}

// Модель штрафів Safety Score: 100 балів, мінус 2 за кожен маневр, мінус 5
// за кожне відволікання і додатково мінус 1 за кожні 10 с з телефоном у руках
// (не більше 5 за одне відволікання), не менше 0. Параметри - у VeloxConfig.
nonisolated enum SafetyScoreCalculator {
    static let maneuverPenalty = VeloxConfig.maneuverPenalty
    static let distractionPenalty = VeloxConfig.distractionPenalty

    /// durationPenalty - сума штрафів за тривалість відволікань (DistractionTracker)
    static func score(maneuvers: Int, distractions: Int, durationPenalty: Int = 0) -> Int {
        max(0, 100 - maneuverPenalty * maneuvers - distractionPenalty * distractions - durationPenalty)
    }

    /// Штраф за тривалість одного відволікання
    static func durationPenalty(for seconds: TimeInterval) -> Int {
        guard seconds > 0 else { return 0 }
        let steps = Int(seconds / VeloxConfig.distractionDurationStep)
        return min(VeloxConfig.distractionDurationPenaltyMax, steps * VeloxConfig.distractionDurationPenalty)
    }
}
