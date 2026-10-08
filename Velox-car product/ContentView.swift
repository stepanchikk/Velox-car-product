import SwiftUI

// Корінь застосунку: екран входу або основне меню, тема оформлення
struct ContentView: View {
    @StateObject private var account = AccountStore()
    @AppStorage(AppSettings.themeKey) private var theme = AppTheme.dark.rawValue

    var body: some View {
        Group {
            if account.isLoggedIn {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .environmentObject(account)
        .tint(VeloxColor.accent)
        .preferredColorScheme((AppTheme(rawValue: theme) ?? .dark).colorScheme)
        .animation(.easeInOut(duration: 0.25), value: account.isLoggedIn)
    }
}
