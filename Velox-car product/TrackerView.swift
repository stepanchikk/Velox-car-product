import SwiftUI

// Екран поїздки: стан запису, оцінка наживо, поздовжнє прискорення, лічильники подій
struct TrackerView: View {
    // Об'єкт створюється в MainTabView і передається через середовище
    @EnvironmentObject private var sensorManager: SensorManager
    @AppStorage(AppSettings.showLiveAccelerationKey) private var showLiveAcceleration = true

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                statusBar
                ScoreGauge(score: sensorManager.isRecording ? sensorManager.safetyScore : nil,
                           caption: sensorManager.isRecording ? "оцінка поточної поїздки" : "запис не йде",
                           lineWidth: 16)
                    .frame(maxWidth: 270)
                    .padding(.top, 4)

                if sensorManager.isCalibrating {
                    calibrationPanel
                } else if !sensorManager.isRecording {
                    idleHint
                }

                counters
                if showLiveAcceleration {
                    AccelerationBar(value: sensorManager.currentGForceY,
                                    threshold: VeloxConfig.maneuverThreshold)
                        .veloxPanel(radius: 18, padding: 16)
                }
                controls
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(VeloxColor.background.ignoresSafeArea())
        // Повідомлення користувачу: помилки сенсора, результат збереження
        .alert("Velox", isPresented: $sensorManager.showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(sensorManager.alertMessage)
        }
    }

    // MARK: Стан

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor(for: sensorManager.phoneState))
                .frame(width: 10, height: 10)
            Text(sensorManager.phoneState.title)
                .font(.headline)
            Spacer()
            if sensorManager.isRecording, !sensorManager.calibrationInfo.isEmpty, !sensorManager.isCalibrating {
                Text(sensorManager.calibrationInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(VeloxColor.panel, in: Capsule())
    }

    private var calibrationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(sensorManager.calibrationInfo, systemImage: "scope")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VeloxColor.medium)
            ProgressView(value: sensorManager.calibrationProgress)
                .tint(VeloxColor.medium)
        }
        .veloxPanel(radius: 18, padding: 16)
    }

    private var idleHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Закріпіть телефон у будь-якому положенні й натисніть «Почати». Перші 2 секунди телефон має бути нерухомим, а потім проїдьте прямо кілька секунд: так Velox визначить напрям руху.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Label(sensorManager.locationStatus.hint, systemImage: locationIcon(for: sensorManager.locationStatus))
                .font(.footnote)
                .foregroundStyle(sensorManager.locationStatus == .authorized ? VeloxColor.safe : .secondary)
        }
        .veloxPanel(radius: 18, padding: 16)
    }

    // MARK: Лічильники

    private var counters: some View {
        HStack(spacing: 0) {
            counter(value: sensorManager.hardBrakingCount, label: "гальмування", color: VeloxColor.danger)
            Divider().frame(height: 44)
            counter(value: sensorManager.hardAccelerationCount, label: "розгони", color: VeloxColor.medium)
            Divider().frame(height: 44)
            counter(value: sensorManager.distractionCount, label: "відволікання", color: VeloxColor.accent,
                    detail: sensorManager.distractionSeconds > 0
                        ? TripFormat.duration(sensorManager.distractionSeconds) : nil)
        }
        .veloxPanel(radius: 18, padding: 14)
    }

    private func counter(value: Int, label: String, color: Color, detail: String? = nil) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value > 0 ? color : .primary)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.25), value: value)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            // Сумарний час з телефоном у руках
            if let detail = detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(color)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Керування

    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                if sensorManager.isRecording {
                    sensorManager.stopRecording()
                } else {
                    // Спершу перевіряється доступ до геолокації (з поясненням)
                    sensorManager.requestStart()
                }
            } label: {
                Label(sensorManager.isRecording ? "Зупинити поїздку" : "Почати поїздку",
                      systemImage: sensorManager.isRecording ? "stop.fill" : "play.fill")
            }
            .buttonStyle(VeloxPrimaryButtonStyle(color: sensorManager.isRecording ? VeloxColor.danger : VeloxColor.accent))
            // Пояснення перед системним запитом дозволу
            .alert("Доступ до геолокації", isPresented: $sensorManager.showLocationPrompt) {
                Button("Дозволити") { sensorManager.allowLocationAndStart() }
                Button("Без геолокації") { sensorManager.startWithoutLocation() }
                Button("Скасувати", role: .cancel) { }
            } message: {
                Text("Velox використовує геолокацію для визначення швидкості під час калібрування: так застосунок дізнається, куди рухається автомобіль, і телефон можна розмістити в будь-якому положенні. Координати зберігаються, лише якщо в налаштуваннях увімкнено «Зберігати маршрут».")
            }

            HStack(spacing: 12) {
                // Ручне перекалібрування: лише під час запису і лише "на стоянці"
                Button {
                    sensorManager.recalibrate()
                } label: {
                    Label("Перекалібрувати", systemImage: "scope")
                }
                .buttonStyle(VeloxSecondaryButtonStyle())
                .disabled(!canRecalibrateNow)

                Button {
                    sensorManager.resetData()
                } label: {
                    Label("Скинути", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(VeloxSecondaryButtonStyle())
            }
            // Доступу немає: відкрити Налаштування або записувати без GPS
            .alert("Геолокація недоступна", isPresented: $sensorManager.showLocationDeniedPrompt) {
                Button("Відкрити Налаштування") { sensorManager.openSettings() }
                Button("Продовжити без GPS") { sensorManager.startWithoutLocation() }
                Button("Скасувати", role: .cancel) { }
            } message: {
                Text(sensorManager.locationDeniedMessage)
            }

            if sensorManager.isRecording && !sensorManager.canManuallyRecalibrate {
                Text("Перекалібрування вручну доступне, коли авто стоїть")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: Допоміжне

    private func locationIcon(for status: LocationAccess) -> String {
        switch status {
        case .authorized: return "location.fill"
        case .notDetermined: return "location"
        case .reducedAccuracy: return "location.circle"
        case .denied: return "location.slash"
        }
    }

    private var canRecalibrateNow: Bool {
        sensorManager.isRecording && !sensorManager.isCalibrating && sensorManager.canManuallyRecalibrate
    }

    // switch без default: якщо додати новий стан, компілятор нагадає задати колір
    private func statusColor(for state: SessionState) -> Color {
        switch state {
        case .idle: return .secondary
        case .calibrating: return VeloxColor.medium
        case .recording: return VeloxColor.safe
        case .distracted: return VeloxColor.danger
        case .onCall: return VeloxColor.accent
        }
    }
}

// MARK: - Шкала поздовжнього прискорення

/// Горизонтальна шкала від гальмування (ліворуч) до розгону (праворуч),
/// з позначками порога маневру
struct AccelerationBar: View {
    let value: Double
    let threshold: Double
    // Діапазон шкали трохи ширший за поріг, щоб було видно перевищення
    private var range: Double { threshold * 1.5 }

    private var position: Double {
        (min(max(value, -range), range) + range) / (2 * range)
    }

    private var color: Color {
        abs(value) > threshold ? (value < 0 ? VeloxColor.danger : VeloxColor.medium) : VeloxColor.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Поздовжнє прискорення")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%+.2f G", value))
                    .font(.system(.headline, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(abs(value) > threshold ? color : .primary)
            }
            GeometryReader { geo in
                let width = geo.size.width
                let thresholdOffset = (threshold / range) * width / 2
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(VeloxColor.panelRaised)
                        .frame(height: 8)
                    // Позначки порога і нуля
                    ForEach([-1.0, 1.0], id: \.self) { side in
                        Rectangle()
                            .fill(VeloxColor.hairline)
                            .frame(width: 2, height: 18)
                            .offset(x: width / 2 + side * thresholdOffset - 1)
                    }
                    Rectangle()
                        .fill(VeloxColor.hairline.opacity(0.6))
                        .frame(width: 1, height: 12)
                        .offset(x: width / 2)
                    Circle()
                        .fill(color)
                        .frame(width: 18, height: 18)
                        .offset(x: position * width - 9)
                        .animation(.easeOut(duration: 0.1), value: position)
                }
                .frame(height: 18)
            }
            .frame(height: 18)
            HStack {
                Text("гальмування")
                Spacer()
                Text("поріг ±\(String(format: "%.1f", threshold)) G")
                Spacer()
                Text("розгін")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
