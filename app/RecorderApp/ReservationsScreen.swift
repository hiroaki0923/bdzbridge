import RecorderKit
import SwiftUI

/// What the recorder is going to record, under the day it records on, or the genre, or the channel.
struct ReservationsScreen: View {
    @Environment(AppModel.self) private var model
    /// The row swiped, by id rather than by value: the reservation itself is read back out of the model
    /// when the dialog asks, so a delete can only ever be sent for a row the list still holds.
    @State private var removing: String?
    @State private var failure: String?
    @State private var opened: Reservation?

    /// One alert does both jobs, because two on the same view is not something SwiftUI promises to honour.
    /// A failure wins: it is the answer to what was just asked.
    private enum Shown {
        case confirm(Reservation)
        case failed(String)
    }

    private var shown: Shown? {
        if let failure { return .failed(failure) }
        if let id = removing, let reservation = model.reservations.first(where: { $0.id == id }) {
            return .confirm(reservation)
        }
        return nil
    }

    private var alertTitle: String {
        if case .failed = shown { return "うまくいきませんでした" }
        return "この予約を削除しますか？"
    }

    var body: some View {
        NavigationStack {
            Group {
                if !model.connected {
                    NoRecorderView(icon: "clock")
                } else {
                    // The empty state sits on top of the list rather than in its place, so that pulling
                    // down still reloads: a reservation just made on the box is exactly what an empty
                    // screen is waiting for, and a plain placeholder has nothing to pull.
                    list.overlay {
                        if model.shownReservations.isEmpty {
                            ContentUnavailableView("予約はありません", systemImage: "clock",
                                                   description: Text("番組表から番組を選んで予約できます"))
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("予約").font(.subheadline.weight(.semibold))
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("種類", selection: Binding(get: { model.reservationKind },
                                                         set: { model.reservationKind = $0 })) {
                            ForEach(AppModel.ReservationKind.allCases, id: \.self) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                        Picker("並び", selection: Binding(get: { model.reservationSort },
                                                         set: { model.reservationSort = $0 })) {
                            ForEach(AppModel.ReservationSort.allCases, id: \.self) { sort in
                                Text(sort.label).tag(sort)
                            }
                        }
                    } label: {
                        Image(systemName: model.reservationSort == .time && model.reservationKind == .all
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("並びを変える")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        RecorderRulesScreen()
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .accessibilityLabel("おまかせ・まる録")
                    .disabled(!model.connected)
                }
            }
            .refreshable { await model.loadReservations() }
            .task(id: model.connected) { await model.loadReservations() }
            .sheet(item: $opened) { ReservationSheet(reservation: $0) }
            // `presenting:` hands the reservation to the buttons. Reading it from the state instead would
            // come up empty: SwiftUI closes the dialog first, and closing it is what clears the state.
            .alert(alertTitle,
                   isPresented: Binding(get: { shown != nil },
                                        set: { if !$0 { removing = nil; failure = nil } }),
                   presenting: shown) { shown in
                switch shown {
                case .confirm(let reservation):
                    Button("削除する", role: .destructive) {
                        Task {
                            if await !model.cancel(reservation) {
                                failure = model.problem ?? "レコーダーが受け付けませんでした"
                            }
                        }
                    }
                    Button("やめる", role: .cancel) {}
                case .failed:
                    Button("OK", role: .cancel) {}
                }
            } message: { shown in
                switch shown {
                case .confirm(let reservation):
                    Text("\(Format.dateTime.string(from: reservation.start)) \(reservation.title)\n"
                         + "レコーダーから消えます。"
                         + (reservation.createdByRecorder
                            ? "\nこれはレコーダーのおまかせ録画が入れた予約です。消してもレコーダーが入れ直すことがあります。"
                            : ""))
                case .failed(let reason):
                    Text(reason)
                }
            }
            // whatever goes wrong here has to be visible on this screen, not only on the others
            .safeAreaInset(edge: .bottom) {
                if let busy = model.busy {
                    Label(busy, systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                } else if let problem = model.problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                }
            }
        }
    }

    private var subtitle: String {
        let shown = model.shownReservations
        let recording = shown.filter(\.recording).count
        let clashing = shown.filter(\.conflict).count
        var parts: [String] = []
        if model.reservationKind != .all { parts.append(model.reservationKind.label) }
        parts.append("\(shown.count) 件")
        if recording > 0 { parts.append("録画中 \(recording)") }
        if clashing > 0 { parts.append("重複 \(clashing)") }
        return parts.joined(separator: " · ")
    }

    private var list: some View {
        List {
            ForEach(model.reservationSections) { section in
                Section(section.title) {
                    ForEach(section.items) { reservation in
                        Button { opened = reservation } label: {
                            ReservationRowView(reservation: reservation,
                                               channel: model.channelName(for: reservation),
                                               logo: model.logo(for: reservation))
                                .rowHitArea()
                        }
                        .buttonStyle(.plain)
                        // `role: .destructive` would animate the row away as it is swiped, before there
                        // is an answer, and it stays away when the answer is no. The colour is all that is
                        // wanted here. A full swipe is off for the same reason: this one asks first.
                        .swipeActions(allowsFullSwipe: false) {
                            Button("削除") { removing = reservation.id }.tint(.red)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct ReservationRowView: View {
    let reservation: Reservation
    let channel: String
    let logo: Data?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Format.time.string(from: reservation.start)).font(.callout.monospacedDigit())
                Text(Format.duration(reservation.durationSec)).font(.caption2).foregroundStyle(.secondary)
                if reservation.recording {
                    Text("録画中").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                }
                if reservation.conflict {
                    Text("重複").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                }
                if reservation.createdByRecorder {
                    Text("おまかせ")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color(.tertiarySystemFill))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                }
            }
            Text(reservation.title).font(.subheadline).lineLimit(2)
            HStack(spacing: 6) {
                // The space is held whether or not there is a logo, so the names line up down the list.
                // Plenty of stations have none: the recorder only has the ones it has been sent.
                Group {
                    if let logo, let image = UIImage(data: logo) {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                }
                .frame(width: 25, height: 14)
                if !channel.isEmpty { Text(channel) }
                if let quality = reservation.qualityName { Text(quality) }
                if let name = reservation.repeatName, name != "none" {
                    Text(Codes.repeatLabel[name] ?? name)
                }
                if let genre = reservation.genreCode.flatMap({ Codes.genreLabel[$0 / 16] }) {
                    Text(genre).foregroundStyle(.tertiary)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
