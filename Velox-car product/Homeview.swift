import SwiftUI
import Charts

// Головна: оцінка водія за останні поїздки, кнопка старту, остання поїздка,
// динаміка оцінки, досягнення і порада дня
struct HomeView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var sensorManager: SensorManager
    @EnvironmentObject private var tripStore: TripStore

    var onStartTrip: () -> Void
    var onOpenTrip: () -> Void

    private var stats: DrivingStats { DrivingStats(trips: tripStore.trips) }
    private var achievements: [Achievement] { AchievementCatalog.evaluate(tripStore.trips) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    greeting
                    cluster
                    if let last = tripStore.trips.first {
                        lastTrip(last)
                    }
                    if stats.recentScores.count >= 2 {
                        trend
                    }
                    achievementStrip
                    tip
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(VeloxColor.background.ignoresSafeArea())
            .navigationDestination(for: TripSummary.self) { trip in
                TripDetailView(trip: trip)
            }
            .navigationDestination(for: String.self) { _ in
                AchievementsView()
            }
        }
    }

    // MARK: Привітання

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Self.greetingWord(for: Date())), \(firstName)")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            if let car = account.profile?.car, !car.isEmpty {
                Label(car, systemImage: "car.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private var firstName: String {
        let name = account.profile?.name ?? ""
        return name.split(separator: " ").first.map(String.init) ?? "водію"
    }

    static func greetingWord(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return "Доброго ранку"
        case 12..<18: return "Добрий день"
        case 18..<23: return "Добрий вечір"
        default: return "Доброї ночі"
        }
    }

    // MARK: Приладова панель

    private var cluster: some View {
        VStack(spacing: 20) {
            // Оцінка водія: штрафи останніх поїздок на 10 км (довгі й короткі
            // поїздки порівнюються чесно); оцінки окремих поїздок - на графіку нижче
            ScoreGauge(score: stats.driverRating, caption: gaugeCaption, lineWidth: 14)
                .frame(maxWidth: 250)
                .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                stat(value: "\(stats.tripCount)", label: "поїздок")
                Divider().frame(height: 36)
                stat(value: TripFormat.distance(stats.totalDistanceMeters), label: "проїхано")
                Divider().frame(height: 36)
                stat(value: TripFormat.duration(stats.totalDuration), label: "за кермом")
            }

            if sensorManager.isRecording {
                Button(action: onOpenTrip) {
                    Label("Повернутися до поїздки", systemImage: "record.circle")
                }
                .buttonStyle(VeloxPrimaryButtonStyle(color: VeloxColor.danger))
            } else {
                Button(action: onStartTrip) {
                    Label("Почати поїздку", systemImage: "play.fill")
                }
                .buttonStyle(VeloxPrimaryButtonStyle())
            }
        }
        .veloxPanel(radius: 28, padding: 20)
    }

    private var gaugeCaption: String {
        let count = stats.recentScoreCount
        guard count > 0 else { return "Запишіть першу поїздку" }
        return "оцінка водія за \(count) \(Self.tripsWord(count))"
    }

    /// 1 поїздку, 2 поїздки, 5 поїздок, 11 поїздок, 21 поїздку
    static func tripsWord(_ count: Int) -> String {
        let lastTwo = count % 100, last = count % 10
        if (11...14).contains(lastTwo) { return "поїздок" }
        switch last {
        case 1: return "поїздку"
        case 2...4: return "поїздки"
        default: return "поїздок"
        }
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.headline, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Остання поїздка

    private func lastTrip(_ trip: TripSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Остання поїздка")
            NavigationLink(value: trip) {
                TripRow(trip: trip)
                    .veloxPanel(radius: 18, padding: 14)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Динаміка

    private var trend: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Оцінка за останні поїздки")
            Chart {
                ForEach(Array(stats.recentScores.enumerated()), id: \.offset) { item in
                    BarMark(x: .value("Поїздка", "\(item.offset + 1)"),
                            y: .value("Safety Score", item.element))
                        .foregroundStyle(SafetyClass.classify(item.element).color)
                        .cornerRadius(4)
                }
                RuleMark(y: .value("Безпечно", VeloxConfig.safeScoreMin))
                    .foregroundStyle(VeloxColor.hairline)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [0, 50, VeloxConfig.safeScoreMin, 100])
            }
            .frame(height: 140)
            .veloxPanel(radius: 18, padding: 14)
            Text("Від старіших до новіших. Пунктир - межа класу «Безпечний водій».")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Досягнення

    private var achievementStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("Досягнення")
                Spacer()
                NavigationLink("Усі", value: "achievements")
                    .font(.subheadline)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(achievements) { achievement in
                        AchievementBadge(achievement: achievement, compact: true)
                    }
                }
            }
            Text("Отримано \(achievements.filter(\.isUnlocked).count) з \(achievements.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Порада

    private var tip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Порада дня", systemImage: "lightbulb")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VeloxColor.medium)
            Text(DrivingTips.tip(for: Date()))
                .font(.callout)
        }
        .veloxPanel(radius: 18, padding: 16)
        .padding(.bottom, 12)
    }
}

// MARK: - Значок досягнення

struct AchievementBadge: View {
    let achievement: Achievement
    var compact = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(VeloxColor.hairline, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: achievement.progress)
                    .stroke(achievement.isUnlocked ? VeloxColor.medium : VeloxColor.accent,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: achievement.systemImage)
                    .font(.system(size: compact ? 20 : 24, weight: .semibold))
                    .foregroundStyle(achievement.isUnlocked ? VeloxColor.medium : .secondary)
            }
            .frame(width: compact ? 56 : 64, height: compact ? 56 : 64)

            Text(achievement.title)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if !compact {
                Text(achievement.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(achievement.progressText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(achievement.isUnlocked ? VeloxColor.medium : VeloxColor.accent)
            }
        }
        .frame(width: compact ? 88 : nil)
        .frame(maxWidth: compact ? nil : .infinity)
        .padding(.vertical, compact ? 4 : 14)
        .padding(.horizontal, compact ? 0 : 8)
        .background {
            if !compact {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(VeloxColor.panel)
            }
        }
        .opacity(achievement.isUnlocked || achievement.progress > 0 ? 1 : 0.65)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Усі досягнення

struct AchievementsView: View {
    @EnvironmentObject private var tripStore: TripStore

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      spacing: 12) {
                ForEach(AchievementCatalog.evaluate(tripStore.trips)) { achievement in
                    AchievementBadge(achievement: achievement)
                }
            }
            .padding(20)
        }
        .background(VeloxColor.background.ignoresSafeArea())
        .navigationTitle("Досягнення")
        .navigationBarTitleDisplayMode(.inline)
    }
}
