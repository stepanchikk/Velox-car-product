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

// Модель штрафів Safety Score: 100 балів, мінус 2 за кожен маневр і мінус 5
// за кожне відволікання, не менше 0 (README, пояснювальна записка, п. 1.3.4)
nonisolated enum SafetyScoreCalculator {
    static let maneuverPenalty = VeloxConfig.maneuverPenalty
    static let distractionPenalty = VeloxConfig.distractionPenalty

    static func score(maneuvers: Int, distractions: Int) -> Int {
        max(0, 100 - maneuverPenalty * maneuvers - distractionPenalty * distractions)
    }
}
