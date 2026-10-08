import SwiftUI
import PhotosUI

// Профіль водія: фото, імʼя, автомобіль, загальна статистика,
// досягнення, налаштування і вихід
struct ProfileView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var sensorManager: SensorManager
    @EnvironmentObject private var tripStore: TripStore

    @State private var pickerItem: PhotosPickerItem?
    @State private var showEditor = false
    @State private var confirmLogout = false

    private var stats: DrivingStats { DrivingStats(trips: tripStore.trips) }
    private var unlockedCount: Int { AchievementCatalog.evaluate(tripStore.trips).filter(\.isUnlocked).count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section {
                    LabeledContent("Поїздок", value: "\(stats.tripCount)")
                    LabeledContent("Проїхано", value: TripFormat.distance(stats.totalDistanceMeters))
                    LabeledContent("За кермом", value: TripFormat.duration(stats.totalDuration))
                    LabeledContent("Середній Safety Score",
                                   value: stats.averageRecentScore.map { "\($0)" } ?? "немає даних")
                } header: {
                    SectionTitle("Статистика")
                } footer: {
                    Text("Середня оцінка рахується за \(DrivingStats.recentWindow) останніми поїздками.")
                }

                Section {
                    NavigationLink {
                        AchievementsView()
                    } label: {
                        LabeledContent {
                            Text("\(unlockedCount)")
                        } label: {
                            Label("Досягнення", systemImage: "rosette")
                        }
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Налаштування", systemImage: "gearshape")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        confirmLogout = true
                    } label: {
                        Label("Вийти з профілю", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    // Вихід під час запису знищив би екран поїздки разом із записом
                    .disabled(sensorManager.isRecording)
                } footer: {
                    if sensorManager.isRecording {
                        Text("Спочатку зупиніть запис поїздки")
                    }
                }
            }
            .veloxScreenBackground()
            .navigationTitle("Профіль")
            .toolbar {
                Button("Змінити") { showEditor = true }
            }
            .sheet(isPresented: $showEditor) {
                EditProfileView()
            }
            .task(id: pickerItem) {
                guard let item = pickerItem else { return }
                if let data = try? await item.loadTransferable(type: Data.self) {
                    account.setAvatar(from: data)
                }
                pickerItem = nil
            }
            .confirmationDialog("Вийти з профілю?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Вийти", role: .destructive) { account.logout() }
                Button("Скасувати", role: .cancel) { }
            } message: {
                Text("Поїздки залишаться на телефоні. Щоб повернутися, увійдіть з тим самим email і паролем.")
            }
        }
    }

    private var header: some View {
        // Мітка PhotosPicker - Sendable-замикання, тому властивості AccountStore
        // (ізольовані на MainActor) читаються заздалегідь у локальні константи
        let avatar = account.avatar
        let name = account.profile?.name ?? ""
        return VStack(spacing: 10) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                AvatarView(image: avatar, name: name, size: 104)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(VeloxColor.accent, in: Circle())
                            .overlay(Circle().stroke(VeloxColor.background, lineWidth: 3))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Змінити фото профілю")
            .contextMenu {
                if account.avatar != nil {
                    Button(role: .destructive) {
                        account.removeAvatar()
                    } label: {
                        Label("Видалити фото", systemImage: "trash")
                    }
                }
            }

            Text(account.profile?.name ?? "")
                .font(.system(.title, design: .rounded).weight(.bold))
            if let car = account.profile?.car, !car.isEmpty {
                Label(car, systemImage: "car.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let profile = account.profile {
                Text("\(profile.email), з Velox від \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

// MARK: - Редагування профілю

struct EditProfileView: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var car = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Імʼя", text: $name)
                        .textContentType(.givenName)
                    TextField("Автомобіль", text: $car)
                } footer: {
                    Text("Email змінити не можна: він використовується для входу.")
                }
            }
            .veloxScreenBackground()
            .navigationTitle("Профіль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Скасувати") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Зберегти") {
                        account.updateProfile(name: name, car: car)
                        dismiss()
                    }
                    .disabled(CredentialsValidator.normalizedName(name).isEmpty)
                }
            }
            .onAppear {
                name = account.profile?.name ?? ""
                car = account.profile?.car ?? ""
            }
        }
    }
}
