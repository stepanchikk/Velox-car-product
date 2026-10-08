import SwiftUI

// Вкладка «Історія»: список збережених поїздок, підсумок поїздки,
// експорт CSV через системне меню «Поділитися» і видалення.
struct TripHistoryView: View {
    @EnvironmentObject private var sensorManager: SensorManager
    @EnvironmentObject private var store: TripStore
    @State private var tripToDelete: TripSummary?

    var body: some View {
        NavigationStack {
            Group {
                if store.trips.isEmpty && !store.isLoading {
                    ContentUnavailableView("Поїздок ще немає",
                                           systemImage: "car",
                                           description: Text("Натисніть «Почати поїздку» на головній або на вкладці «Поїздка»."))
                } else {
                    tripList
                }
            }
            .veloxScreenBackground()
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
                Label("Іде запис: поточна поїздка зʼявиться тут після зупинки", systemImage: "record.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(store.trips) { trip in
                NavigationLink(value: trip) {
                    TripRow(trip: trip)
                }
                .listRowBackground(VeloxColor.panel)
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
        HStack(spacing: 14) {
            scoreBadge
            VStack(alignment: .leading, spacing: 6) {
                Text(trip.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                HStack(spacing: 12) {
                    Label(TripFormat.duration(trip.stats.duration), systemImage: "clock")
                    if let meters = trip.stats.distanceMeters, meters > 0 {
                        Label(TripFormat.distance(meters), systemImage: "road.lanes")
                    }
                    if let maneuvers = trip.stats.maneuvers, let distractions = trip.stats.distractions,
                       maneuvers + distractions > 0 {
                        Label("\(maneuvers + distractions)", systemImage: "exclamationmark.triangle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(CompactLabelStyle())
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var scoreBadge: some View {
        let color = trip.stats.score.map { SafetyClass.classify($0).color } ?? VeloxColor.hairline
        return ZStack {
            Circle()
                .stroke(color.opacity(0.35), lineWidth: 3)
            Circle()
                .trim(from: 0, to: Double(trip.stats.score ?? 0) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(trip.stats.score.map { "\($0)" } ?? "?")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .monospacedDigit()
        }
        .frame(width: 46, height: 46)
    }
}

/// Іконка і текст поруч, з меншим відступом, ніж у стандартного Label
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
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
                }
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("Дата", value: trip.date.formatted(date: .long, time: .shortened))
                LabeledContent("Тривалість", value: TripFormat.duration(trip.stats.duration))
                if let meters = trip.stats.distanceMeters {
                    LabeledContent("Відстань (за GPS)", value: TripFormat.distance(meters))
                }
                LabeledContent("Вимірів", value: "\(trip.stats.samples)")
                LabeledContent("Калібрування", value: calibrationText)
            } header: {
                SectionTitle("Поїздка")
            }

            Section {
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
            } header: {
                SectionTitle("Події")
            }

            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Назва")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(trip.fileName)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
                if let size = trip.fileSize {
                    LabeledContent("Розмір", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                if trip.stats.skippedLines > 0 {
                    Label("Запис обірвався, пропущено неповних рядків: \(trip.stats.skippedLines)",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(VeloxColor.medium)
                }
                ShareLink(item: trip.url) {
                    Label("Експортувати CSV", systemImage: "square.and.arrow.up")
                }
            } header: {
                SectionTitle("Файл")
            }
        }
        .veloxScreenBackground()
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
