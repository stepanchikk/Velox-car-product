import Foundation
import ActivityKit

/// Дані Live Activity поїздки: що показують заблокований екран і Dynamic Island.
///
/// Файл має входити в ОБИДВІ цілі: застосунок (Velox-car product) і розширення
/// VeloxWidgets (Target Membership у File Inspector), бо застосунок ці дані
/// надсилає, а розширення малює.
nonisolated struct VeloxTripAttributes: ActivityAttributes {

    /// Клас оцінки для кольору (межі класів лишаються у VeloxConfig застосунку)
    nonisolated enum Level: String, Codable, Hashable {
        case safe, medium, danger
    }

    nonisolated struct ContentState: Codable, Hashable {
        var score: Int
        var level: Level
        var maneuvers: Int
        var distractions: Int
        var speedKmh: Int?          // nil, якщо GPS мовчить
        var status: String          // «Запис іде», «Екран вимкнено», «Відволікання!»...
        var isDistracted: Bool
    }

    // Не змінюється протягом поїздки: від нього рахується таймер на екрані
    var startedAt: Date
}
