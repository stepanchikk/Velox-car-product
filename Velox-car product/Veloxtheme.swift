import SwiftUI
import UIKit

// Візуальна мова Velox: приладова панель автомобіля вночі.
// Застосунком користуються в машині, часто в темряві, тому за замовчуванням тема
// темна: синювато-чорний "асфальт", пласкі панелі без тіней, один сигнальний
// синій для дій і три кольори-індикатори для класів безпеки.
// Головний впізнаваний елемент - дугова шкала зі штрихами (ScoreGauge),
// як у спідометра. Решта інтерфейсу навмисно стримана.

// MARK: - Кольори

nonisolated enum VeloxColor {
    static let background = dynamic(light: 0xF1F4F8, dark: 0x0F1722)
    static let panel = dynamic(light: 0xFFFFFF, dark: 0x18222F)
    static let panelRaised = dynamic(light: 0xE6ECF2, dark: 0x223042)
    static let hairline = dynamic(light: 0xD3DBE4, dark: 0x2B3A4C)
    static let accent = dynamic(light: 0x1764E8, dark: 0x4C93FF)
    static let safe = dynamic(light: 0x1E9E5A, dark: 0x3DD68C)
    static let medium = dynamic(light: 0xC98A00, dark: 0xF5B83D)
    static let danger = dynamic(light: 0xD83A30, dark: 0xFF5A4F)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? rgb(dark) : rgb(light)
        })
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

// MARK: - Налаштування застосунку

nonisolated enum AppTheme: String, CaseIterable, Identifiable {
    case dark, light, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Темна"
        case .light: return "Світла"
        case .system: return "Як у системі"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

nonisolated enum AppSettings {
    static let themeKey = "appTheme"
    static let hapticsKey = "hapticsEnabled"
    static let showLiveAccelerationKey = "showLiveAcceleration"
    static let saveRouteKey = "saveRoute"

    // Значення за замовчуванням - увімкнено (ключа ще немає в UserDefaults)
    static var hapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: hapticsKey) as? Bool ?? true
    }

    // Маршрут - це особисті дані, тому за замовчуванням вимкнено
    static var saveRouteEnabled: Bool {
        UserDefaults.standard.bool(forKey: saveRouteKey)
    }
}

// MARK: - Панель

extension View {
    /// Пласка панель приладової дошки
    func veloxPanel(radius: CGFloat = 20, padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VeloxColor.panel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Фон екрана для List і ScrollView
    func veloxScreenBackground() -> some View {
        self.scrollContentBackground(.hidden)
            .background(VeloxColor.background.ignoresSafeArea())
    }
}

/// Заголовок секції у звичайному регістрі (List за замовчуванням пише великими літерами)
struct SectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.primary)
            .textCase(nil)
    }
}

// MARK: - Кнопки

struct VeloxPrimaryButtonStyle: ButtonStyle {
    var color: Color = VeloxColor.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(color.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct VeloxSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(VeloxColor.panelRaised.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Дугова шкала Safety Score

/// Дуга на 270° зі штрихами через кожні 10 балів, як шкала спідометра.
/// score = nil - даних ще немає (порожня шкала).
struct ScoreGauge: View {
    let score: Int?
    var caption: String? = nil
    var lineWidth: CGFloat = 12

    private var fraction: Double {
        Double(min(max(score ?? 0, 0), 100)) / 100
    }

    private var color: Color {
        score.map { SafetyClass.classify($0).color } ?? VeloxColor.hairline
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            ZStack {
                // Доріжка шкали
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(VeloxColor.hairline, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(135))
                // Заповнення до поточного значення
                Circle()
                    .trim(from: 0, to: 0.75 * fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .animation(.easeOut(duration: 0.6), value: fraction)
                // Штрихи 0, 10, ... 100; довші на 0, 50, 100
                ForEach(0...10, id: \.self) { i in
                    Capsule()
                        .fill(Double(i) / 10 <= fraction && score != nil ? color.opacity(0.9) : VeloxColor.hairline)
                        .frame(width: 2, height: i % 5 == 0 ? 10 : 6)
                        .offset(y: -(radius - lineWidth - 12))
                        .rotationEffect(.degrees(225 + Double(i) * 27))
                }
                VStack(spacing: 2) {
                    if let score = score {
                        Text("\(score)")
                            .font(.system(size: size * 0.28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.easeInOut(duration: 0.3), value: score)
                        Text(SafetyClass.classify(score).label)
                            .font(.system(size: max(11, size * 0.065), weight: .semibold))
                            .foregroundStyle(color)
                    } else {
                        Text("Немає даних")
                            .font(.system(size: max(13, size * 0.08), weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let caption = caption {
                        Text(caption)
                            .font(.system(size: max(10, size * 0.055)))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 2)
                    }
                }
                .frame(width: size * 0.62)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Підсумкова оцінка у вигляді шкали (використовується в підсумку поїздки)
struct SafetyScoreCard: View {
    var score: Int

    var body: some View {
        ScoreGauge(score: score, caption: "Safety Score")
            .frame(maxWidth: 220)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }
}

// MARK: - Аватар

/// Фото профілю або ініціали, якщо фото немає
struct AvatarView: View {
    let image: UIImage?
    let name: String
    var size: CGFloat = 88

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map { String($0) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    VeloxColor.accent
                    Text(initials)
                        .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
