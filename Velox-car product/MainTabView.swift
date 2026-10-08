import SwiftUI

enum AppTab: Hashable {
    case home, trip, history, profile
}

// Підсумок щойно завершеної поїздки, який показується поверх будь-якої вкладки
struct FinishedTripPresentation: Identifiable {
    let trip: TripSummary
    let notice: String?
    let newAchievements: [Achievement]

    var id: String { trip.id }
}

struct MainTabView: View {
    // SensorManager живе на рівні вкладок: запис не переривається при перемиканні
    // вкладок, а профіль знає, чи йде запис (щоб не дати вийти посеред поїздки).
    // TripStore спільний для головної, історії і профілю.
    @StateObject private var sensorManager = SensorManager()
    @StateObject private var tripStore = TripStore()
    @State private var selectedTab: AppTab = .home
    @State private var finishedTrip: FinishedTripPresentation?

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
        // Поїздка в історії зʼявляється одразу після зупинки, на будь-якій вкладці,
        // а якщо її щойно збережено - відкривається її підсумок
        .task(id: sensorManager.isRecording) {
            let unlockedBefore = unlockedAchievementIDs()
            await tripStore.reload(excluding: sensorManager.currentTripFileName)
            presentFinishedTrip(unlockedBefore: unlockedBefore)
        }
        .sheet(item: $finishedTrip) { item in
            NavigationStack {
                TripDetailView(trip: item.trip,
                               notice: item.notice,
                               newAchievements: item.newAchievements,
                               title: "Поїздку завершено")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Готово") { finishedTrip = nil }
                        }
                    }
            }
            .environmentObject(tripStore)
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

    private func unlockedAchievementIDs() -> Set<String> {
        Set(AchievementCatalog.evaluate(tripStore.trips).filter(\.isUnlocked).map(\.id))
    }

    private func presentFinishedTrip(unlockedBefore: Set<String>) {
        guard let pending = sensorManager.finishedTrip else { return }
        sensorManager.finishedTrip = nil
        guard let trip = tripStore.trips.first(where: { $0.fileName == pending.fileName }) else {
            // Файл не прочитався: показуємо підсумок звичайним повідомленням
            sensorManager.showSavedTripMessage(pending)
            return
        }
        let unlocked = AchievementCatalog.evaluate(tripStore.trips)
            .filter { $0.isUnlocked && !unlockedBefore.contains($0.id) }
        finishedTrip = FinishedTripPresentation(trip: trip,
                                                notice: pending.notice,
                                                newAchievements: unlocked)
    }
}
