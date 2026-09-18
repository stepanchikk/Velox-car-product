import SwiftUI

struct MainTabView: View {
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
    }
}

// Макет профілю
struct ProfileView: View {
    @AppStorage("isLoggedIn") var isLoggedIn: Bool = false
    
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
            .padding(.horizontal, 30)
            .padding(.bottom, 30)
        }
    }
}
