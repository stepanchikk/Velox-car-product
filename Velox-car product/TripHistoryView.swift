import SwiftUI

// Вкладка «Історія»: список збережених поїздок, підсумок поїздки,
// експорт CSV через системне меню «Поділитися» і видалення.
struct TripHistoryView: View {
    @EnvironmentObject private var sensorManager: SensorManager
    @StateObject private var store = TripStore()
    @State private var tripToDelete: TripSummary?

    var body: some View {
        NavigationStack {
            Group {
                if store.trips.isEmpty && !store.isLoading {
                    ContentUnavailableView("Поїздок ще немає",
                                           systemImage: "car",
                                           description: Text("Натисніть «Старт» на вкладці «Трекер», щоб записати першу поїздку."))
                } else {
                    tripList
                }
            }
            .navigationTitle("Історія")
            .navigationDestination(for: TripSummary.self) { trip in
                TripDetailView(trip: trip)
            }
            .toolbar {
                if !store.trips.isEmpty {
                    ShareLink(items: store.trips.map(\.url)) {
                        Label("Поділитися всіма", systemImage: "square.and.arrow.up.on.square")
                    }
                }
            }
            .refreshable {
                await store.reload(excluding: sensorManager.currentTripFileName)
            }
            // Перечитуємо при відкритті вкладки і щойно запис зупинився:
            // поточний (незавершений) файл у список не потрапляє
            .task(id: sensorManager.isRecording) {
                await store.reload(excluding: sensorManager.currentTripFileName)
            }
            .confirmationDialog("Видалити поїздку?",
                                isPresented: Binding(get: { tripToDelete != nil },
                                                     set: { if !$0 { tripToDelete = nil } }),
                                titleVisibility: .visible,
                                presenting: tripToDelete) { trip in
                Button("Видалити", role: .destructive) { store.delete(trip) }
                Button("Скасувати", role: .cancel) { }
            } message: { trip in
                Text("Файл \(trip.fileName) буде видалено з телефона без можливості відновлення.")
            }
            .alert("Помилка",
                   isPresented: Binding(get: { store.errorMessage != nil },
                                        set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(store.errorMessage ?? "")
            }
        }
    }

    private var tripList: some View {
        List {
            if sensorManager.isRecording {
                Label("Іде запис: поточна поїздка з'явиться тут після зупинки", systemImage: "record.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.trips) { trip in
                NavigationLink(value: trip) {
                    TripRow(trip: trip)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        tripToDelete = trip
                    } label: {
                        Label("Видалити", systemImage: "trash")
                    }
                }
                .contextMenu {
                    ShareLink(item: trip.url) {
                        Label("Поділитися CSV", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        tripToDelete = trip
                    } label: {
                        Label("Видалити", systemImage: "trash")
                    }
                }
            }
        }
    }
}

// MARK: - Рядок списку

struct TripRow: View {
    let trip: TripSummary

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(trip.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Text(details)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let score = trip.stats.score {
                Text("\(score)")
                    .font(.system(.title2, design: .rounded).bold())
                    .monospacedDigit()
                    .foregroundStyle(SafetyClass.classify(score).color)
            }
        }
        .padding(.vertical, 4)
    }

    private var details: String {
        var parts = [TripFormat.duration(trip.stats.duration)]
        if let meters = trip.stats.distanceMeters, meters > 0 {
            parts.append(TripFormat.distance(meters))
        }
        if let maneuvers = trip.stats.maneuvers, let distractions = trip.stats.distractions {
            parts.append("маневри: \(maneuvers), відволікання: \(distractions)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Підсумок поїздки

struct TripDetailView: View {
    let trip: TripSummary

    var body: some View {
        List {
            if let score = trip.stats.score {
                Section {
                    SafetyScoreCard(score: score)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            Section("Поїздка") {
                LabeledContent("Дата", value: trip.date.formatted(date: .long, time: .shortened))
                LabeledContent("Тривалість", value: TripFormat.duration(trip.stats.duration))
                if let meters = trip.stats.distanceMeters {
                    LabeledContent("Відстань (за GPS)", value: TripFormat.distance(meters))
                }
                LabeledContent("Вимірів", value: "\(trip.stats.samples)")
                LabeledContent("Калібрування", value: calibrationText)
            }

            Section("Події") {
                if let brakings = trip.stats.hardBrakings,
                   let accelerations = trip.stats.hardAccelerations,
                   let distractions = trip.stats.distractions {
                    LabeledContent("Різкі гальмування", value: "\(brakings)")
                    LabeledContent("Агресивні розгони", value: "\(accelerations)")
                    LabeledContent("Відволікання", value: "\(distractions)")
                } else {
                    Text("Файл записано старою версією: події в ньому не позначено")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Файл") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Назва")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(trip.fileName)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let size = trip.fileSize {
                    LabeledContent("Розмір", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                if trip.stats.skippedLines > 0 {
                    Label("Запис обірвався, пропущено неповних рядків: \(trip.stats.skippedLines)",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                ShareLink(item: trip.url) {
                    Label("Експортувати CSV", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle(trip.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var calibrationText: String {
        switch trip.stats.calibration {
        case .gps: return "за GPS"
        case .fallback: return "без GPS (спрощене)"
        case .unknown: return "немає даних"
        }
    }
}
