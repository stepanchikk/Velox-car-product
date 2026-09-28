import SwiftUI

// Класифікація підсумкової оцінки Safety Score.
// Межі відповідають README: 90-100 безпечно, 75-89 середньо, менше 75 небезпечно.
enum SafetyClass {
    case safe
    case medium
    case dangerous

    static func classify(_ score: Int) -> SafetyClass {
        switch score {
        case 90...100:
            return .safe
        case 75..<90:
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
        case .safe: return .green
        case .medium: return .yellow
        case .dangerous: return .red
        }
    }
}
