import RecorderKit
import SwiftUI

struct ReservationsScreen: View {
    @Environment(AppModel.self) private var model

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
                        ReservationRowView(reservation: reservation)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("予約 \(model.reservations.isEmpty ? "" : "\(model.reservations.count) 件")")
            .refreshable { await model.loadReservations() }
            .task(id: model.connected) { if model.reservations.isEmpty { await model.loadReservations() } }
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
