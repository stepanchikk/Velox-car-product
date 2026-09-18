import SwiftUI

struct ContentView: View {
    @StateObject private var sensorManager = SensorManager()
    
    var body: some View {
        VStack(spacing: 40) {
            Text("Velox")
                .font(.system(size: 40, weight: .black, design: .rounded))
            
            // Блок з показниками акселерометра
            VStack(spacing: 20) {
                Text("G-Force")
                    .font(.headline)
                    .foregroundColor(.gray)
                
                Text("X: \(String(format: "%.2f", sensorManager.filteredX))")
                Text("Y: \(String(format: "%.2f", sensorManager.filteredY))")
                Text("Z: \(String(format: "%.2f", sensorManager.filteredZ))")
            }
            .font(.title)
            .monospacedDigit() // Замінили проблемний рядок на цей
            .padding(30)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(20)
            
            // Кнопка керування
            Button(action: {
                if sensorManager.isRecording {
                    sensorManager.stopSensors()
                } else {
                    sensorManager.startSensors()
                }
            }) {
                Text(sensorManager.isRecording ? "Зупинити" : "Старт")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 200, height: 60)
                    .background(sensorManager.isRecording ? Color.red : Color.green)
                    .cornerRadius(30)
            }
        }
        .padding()
    }
}
