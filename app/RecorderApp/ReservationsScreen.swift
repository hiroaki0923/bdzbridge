import RecorderKit
import SwiftUI

/// What the recorder is going to record, under the day it records on, or the genre, or the channel.
struct ReservationsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var removing: Reservation?
    @State private var opened: Reservation?

    var body: some View {
        NavigationStack {
            Group {
                if !model.connected {
                    ContentUnavailableView("レコーダーが未設定です", systemImage: "clock",
                                           description: Text("設定でレコーダーのアドレスを入れてください"))
                } else if model.shownReservations.isEmpty {
                    ContentUnavailableView("予約はありません", systemImage: "clock",
                                           description: Text("番組表から番組を選んで予約できます"))
                } else {
                    list
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
                    Button {
                        Task { await model.loadReservations() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!model.connected || model.busy != nil)
                }
            }
            .refreshable { await model.loadReservations() }
            .task(id: model.connected) { if model.reservations.isEmpty { await model.loadReservations() } }
            .sheet(item: $opened) { ReservationSheet(reservation: $0) }
            // `presenting:` hands the reservation to the buttons. Reading it from the state instead would
            // come up empty: SwiftUI closes the dialog first, and closing it is what clears the state.
            .confirmationDialog("この予約を削除しますか？",
                                isPresented: Binding(get: { removing != nil },
                                                     set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible,
                                presenting: removing) { reservation in
                Button("削除する", role: .destructive) {
                    Task { await model.cancel(reservation) }
                }
                Button("やめる", role: .cancel) {}
            } message: { reservation in
                Text("\(Format.dateTime.string(from: reservation.start)) \(reservation.title)\n"
                     + "レコーダーから消えます。"
                     + (reservation.createdByRecorder
                        ? "\nこれはレコーダーのおまかせ録画が入れた予約です。消してもレコーダーが入れ直すことがあります。"
                        : ""))
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
                                               channel: model.channelName(for: reservation))
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("削除", role: .destructive) { removing = reservation }
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
