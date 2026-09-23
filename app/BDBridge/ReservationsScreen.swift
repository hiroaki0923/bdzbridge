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
        if case .failed = shown { return "エラー" }
        return "この予約を削除しますか？"
    }

    var body: some View {
        NavigationStack {
            Group {
                // Away from home there is still something to show: what the recorder said last time, and
                // above all what is waiting to be sent to it. Hiding the queue behind a connection is
                // hiding it exactly when it is in use.
                if !model.connected, model.reservations.isEmpty, model.pending.isEmpty {
                    NoRecorderView(icon: "clock")
                } else {
                    // The empty state sits on top of the list rather than in its place, so that pulling
                    // down still reloads: a reservation just made on the box is exactly what an empty
                    // screen is waiting for, and a plain placeholder has nothing to pull.
                    list.overlay {
                        if model.shownReservations.isEmpty, model.pending.isEmpty {
                            ContentUnavailableView("予約はありません", systemImage: "clock",
                                                   description: Text("番組表から番組を選んで予約できます"))
                        }
                    }
                }
            }
            .recorderActivity()
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
                        Picker("並び順", selection: Binding(get: { model.reservationSort },
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
                    .accessibilityLabel("並び順を変更")
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
            // Pulling down is the reader asking, which is the one thing that gets another go at a recorder
            // the app has given up on.
            .refreshable {
                if model.offline {
                    await model.connect()
                } else {
                    await model.loadReservations()
                    await model.flushPending()
                }
            }
            .task(id: model.connected) {
                // The queue is on this device and costs nothing to read, so it is read first: behind the
                // reservations it would have waited out a timeout before appearing, which looked like a
                // queue that had swallowed the reservation.
                await model.loadPending()
                await model.loadReservations()
            }
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
                                failure = model.problem ?? "レコーダーがエラーを返しました"
                            }
                        }
                    }
                    Button("キャンセル", role: .cancel) {}
                case .failed:
                    Button("OK", role: .cancel) {}
                }
            } message: { shown in
                switch shown {
                case .confirm(let reservation):
                    Text("\(Format.dateTime.string(from: reservation.start)) \(reservation.title)\n"
                         + "レコーダーから削除されます。"
                         + (reservation.createdByRecorder
                            ? "\nこれはおまかせ・まる録によって自動登録された予約です。削除してもレコーダーが再登録することがあります。"
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
            if !model.pending.isEmpty {
                Section {
                    ForEach(model.pending) { waiting in
                        PendingRowView(waiting: waiting)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("取り消す") { Task { await model.removePending(waiting) } }.tint(.red)
                            }
                            // A refused one is not sent again by itself, since the answer would be the same;
                            // the reader is the one who knows when whatever it names has changed.
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if waiting.problem != nil {
                                    Button("もう一度送る") { Task { await model.resend(waiting) } }
                                        .tint(.blue)
                                }
                            }
                    }
                } header: {
                    Text("送信待ち \(model.pending.count) 件")
                } footer: {
                    Text("レコーダーに届かなかった予約です。次にレコーダーにつながったときに登録します。"
                         + (model.pending.contains { $0.problem != nil }
                            ? "レコーダーが受け付けなかったものは自動では送り直しません。右にスワイプすると、もう一度送れます。"
                            : ""))
                }
            }
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

    @ScaledMetric(relativeTo: .caption2) private var logoHeight = 14.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if reservation.createdByRecorder {
                // The badge is a shape, which a line of text cannot hold, so it goes under the line when the
                // two do not fit side by side.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { head; recorderBadge }
                    VStack(alignment: .leading, spacing: 4) { head; recorderBadge }
                }
            } else {
                head
            }
            Text(reservation.title).font(.subheadline).lineLimit(2)
            meta.font(.caption2).foregroundStyle(.secondary)
        }
        .rowLinesInFull()
        .padding(.vertical, 2)
    }

    /// When, and the marks, as one line of text: as views side by side, a large text size squeezed each
    /// into a narrow column of its own.
    private var head: Text {
        var line = Text(Format.time.string(from: reservation.start)).font(.callout.monospacedDigit())
            + Text.rowGap
            + Text(Format.duration(reservation.durationSec)).foregroundStyle(.secondary)
        if reservation.recording {
            line = line + Text.rowGap + Text("録画中").fontWeight(.semibold).foregroundStyle(.red)
        }
        if reservation.conflict {
            line = line + Text.rowGap
                + Text("重複").fontWeight(.semibold).foregroundStyle(Color.legibleOrange)
        }
        return line.font(.caption2)
    }

    private var recorderBadge: some View {
        Text("おまかせ")
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color(.tertiarySystemFill))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
    }

    /// The channel and how it records, as one line of text for the same reason. The genre is in the secondary
    /// grey with the rest: it was fainter still, too faint to read.
    private var meta: Text {
        var parts: [Text] = []
        if !channel.isEmpty { parts.append(Text(channel)) }
        if let quality = reservation.qualityName { parts.append(Text(quality)) }
        if let name = reservation.repeatName, name != "none" { parts.append(Text(Codes.repeatLabel[name] ?? name)) }
        if let genre = reservation.genreCode.flatMap({ Codes.genreLabel[$0 / 16] }) { parts.append(Text(genre)) }
        // The logo's space is held whether or not there is one, so the names line up down the list. Plenty
        // of stations have none: the recorder only has the ones it has been sent.
        return parts.reduce(InlineLogo.holdingSpace(logo, height: logoHeight)) { $0 + Text.rowGap + $1 }
    }
}

/// A reservation the recorder has not heard yet. It shows what was asked for, not what the recorder made of
/// it, because the recorder has not made anything of it.
struct PendingRowView: View {
    let waiting: PendingReservation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.caption2)
                    .foregroundStyle(Color.legibleOrange)
                Text(waiting.request.title).lineLimit(2)
            }
            Text(details).font(.caption).foregroundStyle(.secondary)
            if let problem = waiting.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .rowLinesInFull()
        .padding(.vertical, 2)
        .rowHitArea()
    }

    private var details: String {
        var parts = [Format.dateTime.string(from: waiting.request.start), waiting.serviceName]
        if let quality = Codes.quality(code: waiting.request.qualityCode) {
            parts.append(Codes.qualityLabel[quality] ?? quality)
        }
        if waiting.request.eventID == nil { parts.append("時刻指定") }
        return parts.joined(separator: " · ")
    }
}
