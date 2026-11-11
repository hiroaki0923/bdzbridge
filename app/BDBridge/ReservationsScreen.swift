import RecBridgeModel
import RecorderKit
import SwiftUI

/// What the recorder is going to record, and the television when one is registered, under the day it is
/// recorded on, or the genre, or the channel. The two devices' reservations are one list, each row saying
/// which device holds it while there are two to tell apart.
struct ReservationsScreen: View {
    @Environment(AppModel.self) private var model
    /// What is swiped and asked on this screen, and what it says over its list: the model's (`ReservationsState`).
    @State private var state: ReservationsState
    @State private var opened: Reservation?
    @State private var welcoming = false

    init(model: AppModel) {
        _state = State(initialValue: ReservationsState(model: model))
    }

    var body: some View {
        NavigationStack {
            Group {
                // Away from home there is still something to show: what the recorder said last time, and
                // the television, and above all the queue, which is in use exactly then.
                if model.reservationsHaveNoRecorder {
                    NoRecorderView(icon: "clock", welcoming: $welcoming)
                } else {
                    // The empty state sits on top of the list rather than in its place, so that pulling
                    // down still reloads: a plain placeholder has nothing to pull.
                    list.overlay {
                        if model.reservationsAreEmpty {
                            ContentUnavailableView(AppModel.noReservations.title, systemImage: "clock",
                                                   description: Text(AppModel.noReservations.detail ?? ""))
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
                        Text(state.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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
                        Image(systemName: state.narrowedOrSorted ? "line.3.horizontal.decrease.circle.fill"
                                                                  : "line.3.horizontal.decrease.circle")
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
            // the app is not connected to, and at a television: both devices, side by side.
            .refreshable { await model.pullDownReservations() }
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
            .task { await model.loadReservations(of: .tv) }
            .sheet(item: $opened) { ReservationSheet(reservation: $0, model: model) }
            // The reservation picked for deletion is the last recorder's when its lists are let go of: see
            // `timesForgotten`. The sheet closes itself. Not a waiting reservation picked for deletion, which
            // is the reader's and no recorder's. A television's row goes the same way with the television's
            // lists (`tvTimesForgotten`), and neither device's going lets go of a row of the other's.
            .onChange(of: model.timesForgotten) { state.recordersListsLetGo() }
            .onChange(of: model.tvTimesForgotten) { state.televisionsListsLetGo() }
            // `presenting:` hands the reservation to the buttons. Reading it from the state instead would
            // come up empty: SwiftUI closes the dialog first, and closing it is what clears the state.
            .alert(state.askTitle,
                   isPresented: Binding(get: { state.ask != nil }, set: { if !$0 { state.askClosed() } }),
                   presenting: state.ask) { asked in
                if let action = state.actionLabel(for: asked) {
                    Button(action.label, role: action.destructive ? .destructive : nil) { state.act(on: asked) }
                }
                Button(state.closingLabel(for: asked), role: .cancel) {}
            } message: { asked in
                Text(state.message(for: asked))
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
                } else if let problem = model.problem(for: .recorder) ?? model.problem(for: .tv) {
                    Text(problem.asABody)
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

    private var list: some View {
        List {
            ForEach(state.stale) { stale in
                // How old the last list of a device that cannot be asked is, above its rows. The words turn
                // over once a minute. On the list's own ground, as a heading is: in a row's white it reads as a
                // row to tap.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(state.staleLine(stale, at: context.date))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            if !model.pending.isEmpty {
                Section {
                    ForEach(model.pending) { waiting in
                        let heldBack = state.holds(waiting)
                        PendingRowView(waiting: waiting, device: model.deviceSaid(for: waiting),
                                       disk: model.diskShown(waiting))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("削除") { state.deleteWaiting(waiting) }.tint(.red).disabled(heldBack)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if state.offersSendingAgain(waiting) {
                                    Button("もう一度送る") { state.sendAgain(waiting) }
                                        .tint(.blue)
                                        .disabled(heldBack)
                                }
                            }
                    }
                } header: {
                    Text(state.waitingHeading)
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
                            Button("削除") { state.delete(reservation) }
                                .tint(.red)
                                .disabled(state.holdsDeleting(reservation))
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
                Text(problem.asABody).font(.caption).foregroundStyle(.red)
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
