import RecorderKit
import SwiftUI

/// What the recorder is going to record, and the television when one is registered, under the day it is
/// recorded on, or the genre, or the channel. The two devices' reservations are one list, each row saying
/// which device holds it while there are two to tell apart.
struct ReservationsScreen: View {
    @Environment(AppModel.self) private var model
    /// The row swiped, by its key in the list rather than by value: the reservation itself is read back out
    /// of the model when the dialog asks, so a delete can only ever be sent for a row the list still holds.
    /// By its key and not its id, which each device numbers for itself: a television's row is found by no
    /// id among the recorder's, and an id the two share would find the recorder's row for the television's.
    /// The device that holds it is kept with the key: the row is let go of when that device's lists are, and
    /// not when the other's are.
    @State private var removing: Picked?
    /// The same for a reservation waiting to be sent, read back out of the queue.
    @State private var removingPending: String?
    @State private var failure: String?
    /// What a waiting reservation sent again came to, where its row does not say it, or what a sending made
    /// of one the reader was deleting: said once, in the alert.
    @State private var said: String?
    @State private var opened: Reservation?
    @State private var welcoming = false

    private struct Picked {
        var listKey: String
        var device: DeviceSlot
    }

    /// One alert does every job, because two on the same view is not something SwiftUI promises to honour.
    /// A failure wins: it is the answer to what was just asked. So is what a waiting reservation sent again
    /// came to.
    private enum Shown {
        case confirm(Reservation)
        case confirmPending(PendingReservation)
        case failed(String)
        case said(String)
    }

    private var shown: Shown? {
        if let failure { return .failed(failure) }
        if let said { return .said(said) }
        if let removing, let reservation = model.reservation(listKey: removing.listKey) {
            return .confirm(reservation)
        }
        if let id = removingPending, let waiting = model.pending.first(where: { $0.id == id }) {
            return .confirmPending(waiting)
        }
        return nil
    }

    private var alertTitle: String {
        switch shown {
        case .failed: "エラー"
        case .said: "送信待ちの予約"
        case .confirmPending: "送信待ちの予約を削除しますか？"
        case .confirm, nil: "この予約を削除しますか？"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                // Away from home there is still something to show: what the recorder said last time, and
                // the television, and above all the queue, which is in use exactly then.
                if !model.connected, model.allReservations.isEmpty, model.pending.isEmpty {
                    NoRecorderView(icon: "clock", welcoming: $welcoming)
                } else {
                    // The empty state sits on top of the list rather than in its place, so that pulling
                    // down still reloads: a plain placeholder has nothing to pull.
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
            // the app is not connected to, and at a television. The two side by side: neither device's
            // silence holds the other's list up.
            .refreshable {
                async let television: Void? = model.tvHost?.refreshReservations()
                await model.refreshReservations()
                await television
            }
            // Keyed as the recordings are, on `connected` and on what the load itself checks. A connect reads
            // this list by itself, but the waking that a check before an operation does reads it only when it
            // has sent something from the queue, and the screen would go on showing what was read before the
            // recorder slept. A connect that follows silence, with this tab in front, reads the list twice.
            .task(id: model.connected && !model.offline) {
                // The queue is on this device and costs nothing to read, so it is read first: behind the
                // reservations it would wait out a timeout before appearing.
                await model.loadPending()
                await model.loadReservations()
            }
            // The television's list in a task of its own, and not in the one above: keyed on the television
            // as well, that one would have the recorder made sure of, and woken, whenever the television's
            // state moved. A television that cannot be asked is sent nothing by this; a connect that reaches
            // one reads its list itself (`TVHost.reached`).
            .task { await model.tvHost?.loadReservations() }
            .sheet(item: $opened) { ReservationSheet(reservation: $0) }
            // The reservation picked for deletion is the last recorder's when its lists are let go of: see
            // `timesForgotten`. The sheet closes itself. Not a waiting reservation picked for deletion, which
            // is the reader's and no recorder's. A television's row goes the same way with the television's
            // lists (`tvTimesForgotten`), and neither device's going lets go of a row of the other's.
            .onChange(of: model.timesForgotten) { if removing?.device == .recorder { removing = nil } }
            .onChange(of: model.tvTimesForgotten) { if removing?.device == .tv { removing = nil } }
            // `presenting:` hands the reservation to the buttons. Reading it from the state instead would
            // come up empty: SwiftUI closes the dialog first, and closing it is what clears the state.
            .alert(alertTitle,
                   isPresented: Binding(get: { shown != nil }, set: { if !$0 { closeAlert() } }),
                   presenting: shown) { shown in
                switch shown {
                case .confirm(let reservation):
                    Button("削除する", role: .destructive) {
                        Task {
                            if await !model.cancel(reservation) {
                                failure = model.problem(for: reservation.device)
                                    ?? "\(reservation.device.label)がエラーを返しました"
                            }
                        }
                    }
                    Button("キャンセル", role: .cancel) {}
                case .confirmPending(let waiting):
                    Button("削除する", role: .destructive) {
                        Task { if let instead = await model.deleteWaiting(waiting) { said = instead } }
                    }
                    Button("キャンセル", role: .cancel) {}
                case .failed, .said:
                    Button("OK", role: .cancel) {}
                }
            } message: { shown in
                switch shown {
                case .confirm(let reservation):
                    Text("\(Format.dateTime.string(from: reservation.start)) \(reservation.title)\n"
                         + "\(reservation.device.label)から削除されます。"
                         + (reservation.createdByRecorder ? "\n" + RecorderDriver.mayComeBackFromTheList : ""))
                case .confirmPending(let waiting):
                    Text("\(Format.dateTime.string(from: waiting.request.start)) \(waiting.request.title)\n"
                         + "この端末から削除し、\(waiting.target.label)には送りません。")
                case .failed(let reason), .said(let reason):
                    Text(reason)
                }
            }
            // whatever goes wrong here has to be visible on this screen, not only on the others: the
            // recorder's line, and the television's when the recorder has nothing to say
            .safeAreaInset(edge: .bottom) {
                if let busy = model.busy {
                    Label(busy, systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                } else if let problem = model.problem ?? model.problem(for: .tv) {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                }
            }
        }
        .welcomesHere($welcoming)
    }

    /// Lets go of whatever the alert was up for, as it closes.
    private func closeAlert() {
        (removing, removingPending, failure, said) = (nil, nil, nil, nil)
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
            if let since = model.reservationsStaleSince,
               model.shownReservations.contains(where: { $0.device == .recorder }) {
                // The recorder's, by the television's rule just below: a recorder that cannot be asked leaves its
                // last list up, and what is on screen says how old that is, above its rows only.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("レコーダーの予約は\(Self.ago(min(since, context.date.addingTimeInterval(-60))))に読んだものです")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            if let since = model.tvHost?.staleSince, model.shownReservations.contains(where: { $0.device == .tv }) {
                // A television that cannot be asked leaves its last list up, and what is on screen says how
                // old that is -- above its rows only, so not while the kind shown leaves them out. The words
                // turn over once a minute and never say less than one: a count of seconds would stand still
                // until the next turn. On the list's own ground, as a heading is: in a row's white it reads
                // as a row to tap.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("テレビの予約は\(Self.ago(min(since, context.date.addingTimeInterval(-60))))に読んだものです")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            if !model.pending.isEmpty {
                Section {
                    ForEach(model.pending) { waiting in
                        // A television's row is held back while the television works, as its reservations
                        // below are: a sending that is out may have this row in hand. Never by the
                        // recorder's work, and a recorder's row is held back by nothing, as it never was.
                        let heldBack = waiting.target == .tv && model.isBusy(for: .tv)
                        PendingRowView(waiting: waiting, device: model.deviceSaid(for: waiting),
                                       disk: model.diskShown(waiting))
                            // 削除, as on the reservations below it, and asked first like every other delete.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("削除") { removingPending = waiting.id }.tint(.red).disabled(heldBack)
                            }
                            // A refused one is not sent again by itself, since the answer would be the same;
                            // the reader is the one who knows when whatever it names has changed. What it
                            // came to is said here where the row does not say it; a recorder's row says
                            // what it sent on the strip, as it has, and hands nothing back to say.
                            // Nothing to say is not kept: it would take down what another row's sending
                            // put up meanwhile -- a recorder's can be out for as long as a waking takes,
                            // and a television's row sent after it is answered first -- before it was read.
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if waiting.problem != nil {
                                    Button("もう一度送る") {
                                        Task {
                                            if let more = await model.sendAgain(waiting)?.besideItsRow { said = more }
                                        }
                                    }
                                    .tint(.blue)
                                    .disabled(heldBack)
                                }
                            }
                    }
                } header: {
                    Text("送信待ち \(model.pending.count) 件")
                } footer: {
                    Text(model.whatWaitsSays)
                }
            }
            ForEach(model.reservationSections) { section in
                Section(section.title) {
                    ForEach(section.items, id: \.listKey) { reservation in
                        Button { opened = reservation } label: {
                            ReservationRowView(reservation: reservation,
                                               channel: model.channelName(for: reservation),
                                               logo: model.logo(for: reservation),
                                               device: model.tv != nil ? reservation.device.label : nil,
                                               disk: model.diskShown(reservation))
                                .rowHitArea()
                        }
                        .buttonStyle(.plain)
                        // Red without `role: .destructive`, which would animate the row away before there
                        // is an answer (see `titleSwipe`). A full swipe is off as well: this one asks first.
                        .swipeActions(allowsFullSwipe: false) {
                            // A television's row stays listed until its delete has read the list again,
                            // and a second delete sent meanwhile would be answered as if the first had failed.
                            Button("削除") {
                                removing = Picked(listKey: reservation.listKey, device: reservation.device)
                            }
                            .tint(.red)
                            .disabled(reservation.device == .tv && model.isBusy(for: .tv))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// How long ago, in numbers and in Japanese (5 分前, and hours and days as they come): the words are part
    /// of a Japanese sentence wherever the phone is set to, and 昨日 for a list read a day ago would say less
    /// than the count does.
    private static func ago(_ date: Date) -> String {
        date.formatted(.relative(presentation: .numeric).locale(Locale(identifier: "ja_JP")))
    }
}

struct ReservationRowView: View {
    let reservation: Reservation
    let channel: String
    let logo: Data?
    /// The word for the device that holds the reservation, said first on the row's second line. Nil where
    /// there is one device and nothing to tell apart, and the row is then drawn without it.
    var device: String? = nil
    /// The disk it records to, said after the device: only for a recorder's row off the internal disk
    /// (`AppModel.diskShown`), so that nothing changes in a home with no USB disk.
    var disk: String? = nil

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

    /// The device and the disk when they are said, the channel and how it records, as one line of text for the
    /// same reason.
    private var meta: Text {
        var parts: [Text] = []
        if let device { parts.append(Text(device)) }
        if let disk { parts.append(Text(disk)) }
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
    /// The word for the device it waits for, said first on the row's second line. Nil where there is one
    /// device and nothing to tell apart (`AppModel.deviceSaid`), and the row is then drawn without it.
    var device: String? = nil
    /// The disk it is to record to, after the device: only for a recorder's row off the internal disk.
    var disk: String? = nil

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
        var parts = [device, disk, Format.dateTime.string(from: waiting.request.start), waiting.serviceName]
            .compactMap { $0 }
        if let quality = Codes.quality(code: waiting.request.qualityCode) {
            parts.append(Codes.qualityLabel[quality] ?? quality)
        }
        if waiting.request.eventID == nil { parts.append("時刻指定") }
        return parts.joined(separator: " · ")
    }
}
