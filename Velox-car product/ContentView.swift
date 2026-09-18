import SwiftUI

struct ContentView: View {
    // Ця змінна зберігається в пам'яті телефону.
    // Якщо false — показуємо логін, якщо true — головне меню.
    @AppStorage("isLoggedIn") var isLoggedIn: Bool = false
    
    var body: some View {
        if isLoggedIn {
            MainTabView()
        } else {
            LoginView()
        }
    }
}
