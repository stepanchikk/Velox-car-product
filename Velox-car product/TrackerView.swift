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
                DataRow(label: "Вісь Y (Прискорення)", value: sensorManager.currentGForceY)
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(15)
            .padding(.horizontal)
            
            Spacer()
            
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
    }
    
    private func statusColor(for state: String) -> Color {
        if state.contains("Відволікання") { return .red }
        if state.contains("Запис") { return .green }
        return .primary
    }
}

// Компонент для красивого відображення подій
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
