import RecorderKit
import SwiftUI

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
                } else if model.reservations.isEmpty {
                    ContentUnavailableView("予約はありません", systemImage: "clock")
                } else {
                    List(model.reservations) { reservation in
                        Button { opened = reservation } label: {
                            ReservationRowView(reservation: reservation)
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("削除", role: .destructive) { removing = reservation }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("予約 \(model.reservations.isEmpty ? "" : "\(model.reservations.count) 件")")
            .refreshable { await model.loadReservations() }
            .sheet(item: $opened) { ReservationSheet(reservation: $0) }
            .task(id: model.connected) { if model.reservations.isEmpty { await model.loadReservations() } }
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
                     + "レコーダーから消えます。")
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
}

struct ReservationRowView: View {
    let reservation: Reservation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Format.dateTime.string(from: reservation.start)).font(.caption.monospacedDigit())
                if reservation.recording {
                    Text("録画中").font(.caption2).foregroundStyle(.red)
                }
                if reservation.conflict {
                    Text("重複").font(.caption2).foregroundStyle(.orange)
                }
            }
            Text(reservation.title).font(.subheadline).lineLimit(2)
            HStack(spacing: 6) {
                Text(Format.duration(reservation.durationSec))
                if let quality = reservation.qualityName { Text(quality) }
                if let repeatName = reservation.repeatName, repeatName != "none" {
                    Text(Codes.repeatLabel[repeatName] ?? repeatName)
                }
                if reservation.eventID != nil { Text("番組追従") }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
