import SwiftUI

struct MainTabView: View {
    // SensorManager живе на рівні вкладок: запис не переривається при перемиканні
    // вкладок, а профіль знає, чи йде запис (щоб не дати вийти посеред поїздки)
    @StateObject private var sensorManager = SensorManager()

    var body: some View {
        TabView {
            //старий екран з акселерометром
            TrackerView()
                .tabItem {
                    Image(systemName: "gauge")
                    Text("Трекер")
                }
            
            // Новий екран профілю
            ProfileView()
                .tabItem {
                    Image(systemName: "person.fill")
                    Text("Профіль")
                }
        }
        .environmentObject(sensorManager)
    }
}

// Макет профілю
struct ProfileView: View {
    @AppStorage("isLoggedIn") var isLoggedIn: Bool = false
    @EnvironmentObject private var sensorManager: SensorManager
    
    var body: some View {
        VStack(spacing: 20) {
            
            // Блок аватарки з іконкою редагування
            ZStack(alignment: .bottomTrailing) {
                Image("avatar_sample")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 120)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.blue, lineWidth: 3))
                
                // Кнопка камери поверх аватарки
                Circle()
                    .fill(Color.blue)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "camera.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 16))
                    )
                    .offset(x: -5, y: -5)
            }
            .padding(.top, 40)
            
            Text("Степан")
                .font(.title)
                .bold()
            
            Text("Автомобіль: 2024 Toyota RAV4 Hybrid")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Button(action: {
                withAnimation {
                    isLoggedIn = false
                }
            }) {
                Text("Вийти з акаунта")
                    .font(.headline)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(12)
            }
            // Вихід під час запису знищив би екран трекера разом із поїздкою
            .disabled(sensorManager.isRecording)
            .opacity(sensorManager.isRecording ? 0.4 : 1.0)
            .padding(.horizontal, 30)

            if sensorManager.isRecording {
                Text("Спочатку зупиніть запис поїздки")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Spacer().frame(height: 30)
        }
    }
}
