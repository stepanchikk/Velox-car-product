import SwiftUI

struct TrackerView: View {
    // Об'єкт створюється в MainTabView і передається через середовище
    @EnvironmentObject private var sensorManager: SensorManager
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Телеметрія")
                .font(.largeTitle)
                .bold()
                .padding(.top, 20)
            
            // Динамічний статус телефону
            HStack {
                Text("Статус:")
                    .font(.headline)
                Spacer()
                Text(sensorManager.phoneState.title)
                    .bold()
                    .foregroundColor(statusColor(for: sensorManager.phoneState))
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(15)
            .padding(.horizontal)
            
            // Калібрування: прогрес, підказка або результат
            if sensorManager.isCalibrating {
                VStack(alignment: .leading, spacing: 8) {
                    Text(sensorManager.calibrationInfo)
                        .font(.subheadline)
                        .foregroundColor(.orange)
                    ProgressView(value: sensorManager.calibrationProgress)
                        .tint(.orange)
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(15)
                .padding(.horizontal)
            } else if sensorManager.isRecording {
                Text(sensorManager.calibrationInfo)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 6) {
                    Text("Після натискання «Старт» тримайте телефон нерухомо приблизно 2 секунди - калібрування визначить вертикаль автоматично, у будь-якому положенні телефона. Якщо доступна геолокація, після цього проїдьте прямо кілька секунд, щоб визначити напрям руху.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Label(sensorManager.locationStatus.hint, systemImage: locationIcon(for: sensorManager.locationStatus))
                        .font(.caption)
                        .foregroundColor(sensorManager.locationStatus == .authorized ? .green : .secondary)
                }
                .padding(.horizontal)
            }
            
            // Підсумкова оцінка безпеки поїздки
            SafetyScoreCard(score: sensorManager.safetyScore)
                .padding(.horizontal)

            // Штрафні бали (Відволікання)
            EventCard(title: "Відволікання (-5 за кожне)", count: sensorManager.distractionCount, color: .purple)
                .padding(.horizontal)
            
            // Лічильники подій (Маневри)
            HStack(spacing: 15) {
                EventCard(title: "Розгони", count: sensorManager.hardAccelerationCount, color: .orange)
                EventCard(title: "Гальмування", count: sensorManager.hardBrakingCount, color: .red)
            }
            .padding(.horizontal)
            
            // Блок поточного перевантаження
            VStack(spacing: 15) {
                DataRow(label: "Поздовжнє прискорення", value: sensorManager.currentGForceY)
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(15)
            .padding(.horizontal)
            
            Spacer()
            
            // Ручне перекалібрування: лише під час запису і лише "на стоянці"
            // (перекалібрування на ходу вимагає GPS-фази і відволікає від керування)
            VStack(spacing: 4) {
                Button(action: {
                    sensorManager.recalibrate()
                }) {
                    Text("Перекалібрувати")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .cornerRadius(12)
                }
                .disabled(!canRecalibrateNow)
                .opacity(canRecalibrateNow ? 1.0 : 0.4)

                if sensorManager.isRecording && !sensorManager.canManuallyRecalibrate {
                    Text("Доступно лише коли авто стоїть")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            
            // Кнопки управління
            HStack(spacing: 15) {
                Button(action: {
                    if sensorManager.isRecording {
                        sensorManager.stopRecording()
                    } else {
                        // Спершу перевіряється доступ до геолокації (з поясненням)
                        sensorManager.requestStart()
                    }
                }) {
                    Text(sensorManager.isRecording ? "Зупинити" : "Старт")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(sensorManager.isRecording ? Color.red : Color.green)
                        .cornerRadius(12)
                }
                // Пояснення перед системним запитом дозволу
                .alert("Доступ до геолокації", isPresented: $sensorManager.showLocationPrompt) {
                    Button("Дозволити") { sensorManager.allowLocationAndStart() }
                    Button("Без геолокації") { sensorManager.startWithoutLocation() }
                    Button("Скасувати", role: .cancel) { }
                } message: {
                    Text("Velox використовує геолокацію лише для визначення швидкості під час калібрування: так застосунок дізнається, куди рухається автомобіль, і телефон можна розмістити в будь-якому положенні. Координати не зберігаються.")
                }
                
                Button(action: {
                    sensorManager.resetData()
                }) {
                    Text("Скинути")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.gray)
                        .cornerRadius(12)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 30)
            // Доступу немає: відкрити Налаштування або записувати без GPS
            .alert("Геолокація недоступна", isPresented: $sensorManager.showLocationDeniedPrompt) {
                Button("Відкрити Налаштування") { sensorManager.openSettings() }
                Button("Продовжити без GPS") { sensorManager.startWithoutLocation() }
                Button("Скасувати", role: .cancel) { }
            } message: {
                Text(sensorManager.locationDeniedMessage)
            }
        }
        // Повідомлення користувачу: помилки сенсора, результат збереження
        .alert("Velox", isPresented: $sensorManager.showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(sensorManager.alertMessage)
        }
    }
    
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
        case .idle: return .primary
        case .calibrating: return .orange
        case .recording: return .green
        case .distracted: return .red
        }
    }
}

// Компонент для красивого відображення подій
// Велика картка з підсумковою оцінкою Safety Score та її класифікацією
struct SafetyScoreCard: View {
    var score: Int

    private var safetyClass: SafetyClass {
        SafetyClass.classify(score)
    }

    var body: some View {
        VStack(spacing: 6) {
            Text("Safety Score")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            Text("\(score)")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundColor(safetyClass.color)
                // Моноширинні цифри, щоб зміна 99 -> 100 не "стрибала" по ширині
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.3), value: score)

            Text("\(safetyClass.emoji) \(safetyClass.label)")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(15)
    }
}

struct EventCard: View {
    var title: String
    var count: Int
    var color: Color
    
    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Text("\(count)")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(15)
    }
}

struct DataRow: View {
    var label: String
    var value: Double

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.primary)
            Spacer()
            Text(String(format: "%.3f G", value))
                .bold()
                .font(.system(.body, design: .monospaced))
                .foregroundColor(abs(value) > SensorManager.maneuverThreshold ? .red : .primary)
        }
    }
}
