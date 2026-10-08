import SwiftUI

enum AppTab: Hashable {
    case home, trip, history, profile
}

struct MainTabView: View {
    // SensorManager живе на рівні вкладок: запис не переривається при перемиканні
    // вкладок, а профіль знає, чи йде запис (щоб не дати вийти посеред поїздки).
    // TripStore спільний для головної, історії і профілю.
    @StateObject private var sensorManager = SensorManager()
    @StateObject private var tripStore = TripStore()
    @State private var selectedTab: AppTab = .home

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(onStartTrip: startTrip, onOpenTrip: { selectedTab = .trip })
                .tabItem { Label("Головна", systemImage: "house.fill") }
                .tag(AppTab.home)

            TrackerView()
                .tabItem { Label("Поїздка", systemImage: "steeringwheel") }
                .tag(AppTab.trip)

            TripHistoryView()
                .tabItem { Label("Історія", systemImage: "clock.arrow.circlepath") }
                .tag(AppTab.history)

            ProfileView()
                .tabItem { Label("Профіль", systemImage: "person.crop.circle") }
                .tag(AppTab.profile)
        }
        .environmentObject(sensorManager)
        .environmentObject(tripStore)
        // Поїздка в історії зʼявляється одразу після зупинки, на будь-якій вкладці
        .task(id: sensorManager.isRecording) {
            await tripStore.reload(excluding: sensorManager.currentTripFileName)
        }
    }

    // «Почати поїздку» на головній: переходимо на вкладку поїздки і стартуємо там,
    // щоб діалоги про геолокацію показались на правильному екрані
    private func startTrip() {
        selectedTab = .trip
        DispatchQueue.main.async {
            sensorManager.requestStart()
        }
    }
}
