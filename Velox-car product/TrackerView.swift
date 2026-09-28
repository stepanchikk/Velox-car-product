import SwiftUI

struct TrackerView: View {
    @StateObject private var sensorManager = SensorManager()
    
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
                Text(sensorManager.phoneState)
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
                Text("Після натискання «Старт» тримайте телефон нерухомо приблизно 2 секунди - калібрування визначить вертикаль автоматично, у будь-якому положенні телефона. Якщо доступна геолокація, після цього проїдьте прямо кілька секунд, щоб визначити напрям руху.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            // Підсумкова оцінка безпеки поїздки
            SafetyScoreCard(score: sensorManager.safetyScore)
                .padding(.horizontal)

            // Штрафні бали (Відволікання)
            EventCard(title: "Штраф: Відволікання", count: sensorManager.distractionScore, color: .purple)
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
                        sensorManager.startRecording()
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
        }
        // Повідомлення користувачу: помилки сенсора, результат збереження
        .alert("Velox", isPresented: $sensorManager.showAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(sensorManager.alertMessage)
        }
    }
    
    private var canRecalibrateNow: Bool {
        sensorManager.isRecording && !sensorManager.isCalibrating && sensorManager.canManuallyRecalibrate
    }

    private func statusColor(for state: String) -> Color {
        if state.contains("Калібрування") { return .orange }
        if state.contains("Відволікання") { return .red }
        if state.contains("Запис") { return .green }
        return .primary
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
