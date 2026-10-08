import SwiftUI

// Налаштування: вигляд, поведінка під час поїздки, геолокація, дані,
// пояснення моделі оцінки, видалення профілю
struct SettingsView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var sensorManager: SensorManager
    @EnvironmentObject private var tripStore: TripStore

    @AppStorage(AppSettings.themeKey) private var theme = AppTheme.dark.rawValue
    @AppStorage(AppSettings.hapticsKey) private var haptics = true
    @AppStorage(AppSettings.showLiveAccelerationKey) private var showLiveAcceleration = true

    @State private var confirmDeleteTrips = false
    @State private var confirmDeleteProfile = false

    var body: some View {
        List {
            Section {
                Picker("Тема", selection: $theme) {
                    ForEach(AppTheme.allCases) { item in
                        Text(item.title).tag(item.rawValue)
                    }
                }
            } header: {
                SectionTitle("Вигляд")
            } footer: {
                Text("Темна тема менше сліпить уночі за кермом.")
            }

            Section {
                Toggle("Вібрація на подіях", isOn: $haptics)
                Toggle("Шкала прискорення на екрані поїздки", isOn: $showLiveAcceleration)
            } header: {
                SectionTitle("Поїздка")
            } footer: {
                Text("Вібрація підказує про різкий маневр чи відволікання, не відриваючи погляду від дороги.")
            }

            Section {
                Label(sensorManager.locationStatus.hint, systemImage: "location")
                Button("Відкрити налаштування iOS") {
                    sensorManager.openSettings()
                }
            } header: {
                SectionTitle("Геолокація")
            } footer: {
                Text("Швидкість за GPS потрібна лише для калібрування напряму руху. Координати не зберігаються.")
            }

            Section {
                LabeledContent("Поїздок на телефоні", value: "\(tripStore.trips.count)")
                LabeledContent("Займають", value: ByteCountFormatter.string(fromByteCount: tripsSize, countStyle: .file))
                Button("Видалити всі поїздки", role: .destructive) {
                    confirmDeleteTrips = true
                }
                .disabled(tripStore.trips.isEmpty || sensorManager.isRecording)
            } header: {
                SectionTitle("Дані")
            }

            Section {
                LabeledContent("Поріг різкого маневру", value: String(format: "%.1f G", VeloxConfig.maneuverThreshold))
                LabeledContent("Штраф за маневр", value: "-\(VeloxConfig.maneuverPenalty)")
                LabeledContent("Штраф за відволікання", value: "-\(VeloxConfig.distractionPenalty)")
                LabeledContent("За тривалість відволікання",
                               value: "-\(VeloxConfig.distractionDurationPenalty) за кожні \(Int(VeloxConfig.distractionDurationStep)) с, до -\(VeloxConfig.distractionDurationPenaltyMax)")
                LabeledContent("Безпечний водій", value: "від \(VeloxConfig.safeScoreMin)")
                LabeledContent("Середній рівень", value: "від \(VeloxConfig.mediumScoreMin)")
            } header: {
                SectionTitle("Як рахується Safety Score")
            } footer: {
                Text("Кожна поїздка починається зі 100 балів. Різкі маневри і користування телефоном під час руху знижують оцінку. Вхідний дзвінок і розмова через гучний звʼязок, гарнітуру чи CarPlay не штрафуються, а розмова з телефоном біля вуха вважається відволіканням.")
            }

            Section {
                LabeledContent("Версія", value: appVersion)
                Button("Видалити профіль з телефона", role: .destructive) {
                    confirmDeleteProfile = true
                }
                .disabled(sensorManager.isRecording)
            } header: {
                SectionTitle("Про застосунок")
            }
        }
        .veloxScreenBackground()
        .navigationTitle("Налаштування")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Видалити всі поїздки?", isPresented: $confirmDeleteTrips, titleVisibility: .visible) {
            Button("Видалити \(tripStore.trips.count)", role: .destructive) { tripStore.deleteAll() }
            Button("Скасувати", role: .cancel) { }
        } message: {
            Text("CSV-файли буде видалено з телефона без можливості відновлення. Щоб зберегти їх, спершу експортуйте в «Історії».")
        }
        .confirmationDialog("Видалити профіль?", isPresented: $confirmDeleteProfile, titleVisibility: .visible) {
            Button("Видалити профіль", role: .destructive) { account.deleteProfile() }
            Button("Скасувати", role: .cancel) { }
        } message: {
            Text("Буде видалено імʼя, фото і дані входу. Поїздки залишаться на телефоні.")
        }
    }

    private var tripsSize: Int64 {
        tripStore.trips.compactMap(\.fileSize).reduce(0, +)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
