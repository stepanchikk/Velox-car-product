import ActivityKit
import SwiftUI
import WidgetKit

// Live Activity поїздки Velox: заблокований екран і Dynamic Island.
// Ціль VeloxWidgets (Widget Extension); дані - VeloxTripAttributes.swift зі спільного файлу.
struct VeloxTripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VeloxTripAttributes.self) { context in
            LockScreenTripView(state: context.state, startedAt: context.attributes.startedAt)
                .activityBackgroundTint(TripPalette.background)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(context.state.score)")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(TripPalette.color(for: context.state.level))
                        Text("Safety Score")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SpeedView(speed: context.state.speedKmh)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        CountersView(state: context.state)
                        Spacer()
                        Text(context.attributes.startedAt, style: .timer)
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 70, alignment: .trailing)
                    }
                    .font(.subheadline)
                }
            } compactLeading: {
                Image(systemName: context.state.isDistracted ? "iphone.gen3.radiowaves.left.and.right" : "car.fill")
                    .foregroundStyle(context.state.isDistracted ? TripPalette.danger : TripPalette.accent)
            } compactTrailing: {
                Text("\(context.state.score)")
                    .monospacedDigit()
                    .foregroundStyle(TripPalette.color(for: context.state.level))
            } minimal: {
                Text("\(context.state.score)")
                    .monospacedDigit()
                    .foregroundStyle(TripPalette.color(for: context.state.level))
            }
            .keylineTint(TripPalette.color(for: context.state.level))
        }
    }
}

// MARK: - Заблокований екран

struct LockScreenTripView: View {
    let state: VeloxTripAttributes.ContentState
    let startedAt: Date

    var body: some View {
        HStack(spacing: 16) {
            ScoreRing(score: state.score, color: TripPalette.color(for: state.level))
                .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 6) {
                Text(state.status)
                    .font(.headline)
                    .foregroundStyle(state.isDistracted ? TripPalette.danger : .white)
                CountersView(state: state)
                    .font(.subheadline)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(startedAt, style: .timer)
                    .font(.headline.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80, alignment: .trailing)
                SpeedView(speed: state.speedKmh)
            }
        }
        .padding(16)
        .foregroundStyle(.white)
    }
}

// MARK: - Складові

struct ScoreRing: View {
    let score: Int
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.25), lineWidth: 6)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(score, 100))) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
    }
}

struct CountersView: View {
    let state: VeloxTripAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Label("\(state.maneuvers)", systemImage: "exclamationmark.triangle.fill")
            Label("\(state.distractions)", systemImage: "iphone")
        }
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.75))
    }
}

struct SpeedView: View {
    let speed: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(speed.map(String.init) ?? "-")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text("км/год")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

// Кольори застосунку в темній темі (VeloxColor недоступний у розширенні)
enum TripPalette {
    static let background = Color(red: 15 / 255, green: 23 / 255, blue: 34 / 255)    // 0F1722
    static let accent = Color(red: 76 / 255, green: 147 / 255, blue: 255 / 255)      // 4C93FF
    static let safe = Color(red: 61 / 255, green: 214 / 255, blue: 140 / 255)        // 3DD68C
    static let medium = Color(red: 245 / 255, green: 184 / 255, blue: 61 / 255)      // F5B83D
    static let danger = Color(red: 255 / 255, green: 90 / 255, blue: 79 / 255)       // FF5A4F

    static func color(for level: VeloxTripAttributes.Level) -> Color {
        switch level {
        case .safe: return safe
        case .medium: return medium
        case .danger: return danger
        }
    }
}
