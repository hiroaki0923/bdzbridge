import RecorderKit
import SwiftUI

/// One programme: what it is, whether the recorder is already set to record it -- or will be, once a
/// reservation waiting on this phone reaches it -- and the two choices that go with a new reservation.
///
/// With a television saved the same is said of the television beside that, each device under its own name,
/// and a new reservation says where it goes (予約先): to a device that neither holds the programme nor has
/// it waiting (`AppModel.destinations(for:)`), so what one device holds neither stands in for a reservation
/// on the other nor is in the way of one. What is offered under it is the chosen device's: the recorder's
/// modes, repeats and what it would clash with (`RecorderDriver`), or the one mode and the repeats a
/// television is sent (`TVDriver`); and what the question before reserving says of the device is its driver's
/// too. The television is asked nothing until the reader reserves, and what that came to is said
/// in the one alert, a case of the result to a case of it (`say`).
///
/// With the recorder alone none of that is drawn, and the sheet is the one it has always been. So with the
/// recorder's disk: a new reservation on the recorder says which disk it records to (録画先) only while a USB
/// disk that takes recordings is known, and a reservation or a row that waits names its disk only off the
/// internal one.
struct ProgramSheet: View {
    let program: GuideProgramRow
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Starts at the mode chosen in the settings, and choosing another here is for this reservation only.
    @State private var quality = DefaultQuality.current
    @State private var repeating = "none"
    @State private var conflicts: [Reservation]?
    @State private var checking = false
    /// What the one alert is for: SwiftUI does not promise to honour two on one view, and asking and reporting
    /// never happen at once. Reporting is here because the red line at the sheet's foot is below the fold.
    private enum Ask {
        /// A reservation on the device 録画予約 was for as its button was pressed. The question keeps that
        /// device, and its words and its button use no other: the lists can be read again while it is up. It
        /// keeps the recorder's disk the same way, as the reader picked it, and names it: nil, and no disk
        /// named, where no disk was there to pick.
        case reserve(DeviceSlot, disk: String?)
        case cancel(Reservation)
        case cancelPending(PendingReservation)
        case failed(String)
        /// The reservation is waiting instead of made, and the sentence for why. `stays`: the sheet is left
        /// open on the row, which waited before or does not go by itself.
        case kept(String, stays: Bool)
        /// Made, and what the television had to say of it; or made by a sending while the reader was deleting
        /// the row it waited in, said as such a sending says it.
        case said(String)
        /// Making it would stop others from recording, which the row's reason names: whether to make it
        /// all the same. `fresh`: it was asked for just now, so a no takes the row off again.
        case wouldStop(PendingReservation, fresh: Bool)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }
    @State private var ask: Ask?
    @State private var done = false
    /// The reservation whose own sheet is open for changing it.
    @State private var editing: Reservation?
    /// Set when the recorder's lists were let go of under this sheet, until another recorder is attached and
    /// asked what the reservation would clash with there; `checks` is what has it asked.
    @State private var lastRecorderGone = false
    @State private var checks = 0
    /// The device the reader picked under 予約先, for as long as it is free for the programme.
    @State private var chosen: DeviceSlot?
    /// The recorder's disk the reader picked under 録画先, kept as picked though it is no longer offered: a
    /// reservation to it is then refused when it is sent rather than sent to the internal disk in its place.
    /// Nil until a disk is picked, and every sheet starts on the internal disk. A disk refused for being no
    /// longer offered puts it on the internal disk, named, so that the next press does not ask for it again.
    @State private var chosenDisk: String?
    /// The device a reservation asked for here is for, from 録画予約する until what it came to has been said
    /// and closed: see `device`.
    @State private var turn: DeviceSlot?
    /// The line of a request of this sheet's own to the television, while it is out. Nothing on the sheet
    /// can be pressed under it and the sheet cannot be closed: what the request came to is said here, in
    /// the alert, and a sheet that had gone would say it nowhere. Never set for the recorder.
    @State private var asking: String?
    /// How many requests of this sheet's own are out and not under `asking`: a reservation on the recorder
    /// or one of its rows sent again, and a delete of a reservation or of a waiting row. A request to the
    /// television does not begin while there is one. As it ends, such a request closes the sheet, or puts
    /// up its own answer and takes `asking` down, and one begun first would do that under the television's:
    /// the sheet gone while the television's answer is still out, or left open to be pressed and closed
    /// while its round runs. Read by the television's three buttons -- 録画予約する, もう一度送る and the way to
    /// change its reservation, whose sheet would send a request of its own -- and by nothing else, and with
    /// the recorder alone none is drawn.
    @State private var others = 0

    /// The recorder's reservation of this programme, and the television's, held apart.
    private var reservation: Reservation? { model.reservations(for: program).first { $0.device == .recorder } }
    private var televisions: Reservation? { model.reservations(for: program).first { $0.device == .tv } }
    private var past: Bool { program.end <= Date() }

    /// The device 録画予約 is for, or nil when no device is free for the programme: the one the reader
    /// picked while it is free, and otherwise the first that is, the recorder before the television.
    ///
    /// In a home with two it is not read afresh in the middle of a reservation (`turn`). A television's
    /// leaves the television no longer free -- the row waits, or was made -- and falling back to the
    /// recorder there would change the section under the question or the answer, and have the recorder
    /// asked what a reservation would clash with (`check`) on account of one that was the television's.
    private var device: DeviceSlot? {
        if let turn, model.destinations.count > 1 { return turn }
        let free = model.destinations(for: program)
        return chosen.flatMap { free.contains($0) ? $0 : nil } ?? free.first
    }

    /// The disk the reader picked while it is no longer offered: let go of since, still shown as a value under
    /// 録画先, and refused when it is sent. Nil while what was picked is offered, and while nothing was picked.
    private var pickedAndGone: String? {
        chosenDisk.flatMap { RecorderDisk.offers($0, with: model.usbDisk) ? nil : $0 }
    }

    /// The disk the clashes are asked for: the one the row under 録画先 shows. Nil while that is a disk no longer
    /// offered, which is asked nothing: the clashes on another disk would not be the ones of the disk shown, and
    /// a reservation to it is refused before anything is sent.
    private var checkedDisk: String? {
        pickedAndGone == nil ? model.diskOffered(chosenDisk) : nil
    }

    /// The disk the question before reserving names and the reservation is sent to: the one picked, or the
    /// internal disk where a picker was there and nothing was picked; nil where there was nothing to pick.
    private var askedDisk: String? {
        chosenDisk ?? (model.diskChoices.isEmpty ? nil : RecorderDisk.internalID)
    }

    /// What a reservation on the recorder can be given, as its driver offers them: the weekly one only on the
    /// programme's own weekday (`RecorderDriver.repeats(startingAt:)`).
    private var repeatOptions: [String] { RecorderDriver.repeats(startingAt: program.start) }

    var body: some View {
        NavigationStack {
            List {
                WakingSection()
                Section {
                    Text(program.title).font(.headline)
                    LabeledContent("放送", value: program.serviceName)
                    LabeledContent("開始", value: Format.dateTime.string(from: program.start))
                    LabeledContent("長さ", value: Format.duration(program.durationSec))
                    if let genre = program.genre?.label {
                        LabeledContent("ジャンル", value: genre)
                    }
                }

                if let reservation {
                    Section(heading("この番組は予約済みです")) {
                        LabeledContent("録画モード", value: reservation.qualityName ?? "-")
                        LabeledContent("毎回録画",
                                       value: Codes.repeatLabel[reservation.repeatName ?? ""] ?? "しない")
                        if let shown = model.diskShown(reservation) { LabeledContent("録画先", value: shown) }
                        if reservation.recording { Text("録画中です").foregroundStyle(.red) }
                        // Changing it happens on the reservation's own sheet rather than here, so there is
                        // one place that does it and one set of pickers to keep right. Not offered where that
                        // sheet's change would be turned away: being recorded, or over.
                        if RecorderDriver.whyNot(changing: reservation) == nil {
                            Button("予約を変更する") { editing = reservation }
                        }
                        Button("予約を削除", role: .destructive) { ask = .cancel(reservation) }
                            .disabled(model.isBusy(for: .recorder))
                    }
                }
                if let televisions {
                    televisionSection(televisions)
                }
                if let waiting = model.pending(for: program, on: .recorder) {
                    pendingSection(waiting)
                }
                if let waiting = model.pending(for: program, on: .tv) {
                    pendingSection(waiting)
                }
                if let asking {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(asking).font(.callout)
                        }
                    }
                }
                // Not for a programme already waiting: a second reservation would only replace it in the queue.
                if device == .recorder, !past {
                    Section("録画予約") {
                        destinationRow(.recorder)
                        NewDiskRow(chosen: $chosenDisk)
                        Picker("録画モード", selection: $quality) {
                            ForEach(RecorderDriver.recordsIn, id: \.self) { code in
                                Text(Codes.qualityLabel[code] ?? code).tag(code)
                            }
                        }
                        Picker("毎回録画", selection: $repeating) {
                            ForEach(repeatOptions, id: \.self) { key in
                                Text(Codes.repeatLabel[key] ?? key).tag(key)
                            }
                        }
                        conflictRow
                        // Alive even while the recorder is being woken or cannot be reached at all: a
                        // reservation made now goes to the queue and is sent when the recorder next answers.
                        // With a disk picked and let go of since, what 予約する would do is done at once: the
                        // question would promise a registration the recorder's driver is about to refuse.
                        Button("録画予約する") {
                            turn = .recorder
                            if let gone = pickedAndGone {
                                reserve(on: .recorder, disk: gone)
                            } else {
                                ask = .reserve(.recorder, disk: askedDisk)
                            }
                        }
                        .disabled(model.working)
                    }
                } else if device == .tv, !past {
                    televisionOffer
                }

                if !program.summary.isEmpty {
                    Section("番組内容") { Text(program.summary) }
                }
                if !program.extended.isEmpty {
                    Section("詳細") { Text(program.extended) }
                }
                if let problem = model.problem {
                    Section { Text(problem).foregroundStyle(.red).font(.callout) }
                }
            }
            .disabled(asking != nil)
            .navigationTitle("番組")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseButton().disabled(asking != nil) }
            .interactiveDismissDisabled(asking != nil)
            .task(id: taskKey) { await check() }
            // The queue on screen is otherwise read when the reservations tab has been opened or a device
            // was connected to, and a programme that waits for the television unread would be offered here
            // as one it can still be reserved on. With the recorder alone the sheet reads what it always has.
            .task { if model.tv != nil { await model.loadPending() } }
            // A repeat picked under the recorder is not carried to the television, which is not sent all of
            // them: whenever 録画予約 becomes the television's, by the reader's choice or by the recorder
            // turning out to hold the programme, it starts from none.
            .onChange(of: device) { if $1 == .tv { repeating = "none" } }
            .sheet(item: $editing) { ReservationSheet(reservation: $0) }
            // The programme is the broadcast's, and this sheet stays when the recorder's lists are let go of
            // (`AppModel.timesForgotten`). What it holds of that recorder goes: the reservation picked for
            // deletion, whose number would go to the next recorder, and the clashes that recorder named, which
            // the next one attached is asked for. A reservation's sheet open over this one closes itself.
            // A television's reservation picked for deletion is not the recorder's to take, and goes with
            // the television's lists instead (`AppModel.tvTimesForgotten`). So does the question whether to
            // make a reservation that would stop others there: the names in it are that television's.
            // What the reader picked of the recorder goes too: a disk picked, and the question that names one
            // off the internal disk, a disk of the recorder let go of. One naming none, as in a home with no USB
            // disk, stays.
            .onChange(of: model.timesForgotten) {
                if case .cancel(let picked) = ask, picked.device == .recorder { ask = nil }
                if case .reserve(.recorder, let named?) = ask, named != RecorderDisk.internalID {
                    (ask, turn) = (nil, nil)
                }
                chosenDisk = nil
                conflicts = nil
                lastRecorderGone = true
            }
            // A disk let go of while the question that names it is up: the question would promise a
            // registration the recorder's driver is about to refuse. It goes, as above, and 録画予約する says why.
            .onChange(of: model.usbDisk) {
                if case .reserve(.recorder, let named?) = ask, !RecorderDisk.offers(named, with: model.usbDisk) {
                    (ask, turn) = (nil, nil)
                }
            }
            .onChange(of: model.tvTimesForgotten) {
                if case .cancel(let picked) = ask, picked.device == .tv { ask = nil }
                if case .wouldStop = ask { (ask, turn) = (nil, nil) }
            }
            .onChange(of: model.timesAttached) {
                guard lastRecorderGone else { return }
                lastRecorderGone = false
                checks += 1
            }
            .alert(askTitle, isPresented: Binding(get: { ask != nil },
                                                  set: { if !$0 { ask = nil } }),
                   presenting: ask) { asked in
                switch asked {
                case .reserve(let device, let named):
                    Button("予約する") { reserve(on: device, disk: named) }
                case .cancel(let reservation):
                    Button("削除する", role: .destructive) {
                        others += 1
                        Task {
                            let deleted = await model.cancel(reservation)
                            others -= 1
                            switch deleted {
                            case .done: done = true
                            case .notDone(let why): ask = .failed(why)
                            }
                        }
                    }
                case .cancelPending(let waiting):
                    Button("削除する", role: .destructive) {
                        others += 1
                        Task {
                            // A television's row is not deleted while the television works, and stays on
                            // the sheet then: a sending begun under the question may have it in hand. One a
                            // sending made first is said as made, and the sheet closes once that is read.
                            let instead = await model.deleteWaiting(waiting)
                            others -= 1
                            if let instead {
                                ask = .said(instead)
                            } else {
                                done = waiting.target != .tv || model.pending(for: program, on: .tv) == nil
                            }
                        }
                    }
                case .wouldStop(let held, let fresh):
                    Button("それでも予約") {
                        request(under: TVDriver.sendingLine, fresh: fresh) {
                            await model.consent(to: held, askedForJustNow: fresh)
                        }
                    }
                case .failed, .kept, .said:
                    EmptyView()
                }
                switch asked {
                case .kept(_, let stays):
                    Button("OK", role: .cancel) { if stays { turn = nil } else { done = true } }
                case .said:
                    Button("OK", role: .cancel) { done = true }
                case .wouldStop(let held, let fresh):
                    Button("キャンセル", role: .cancel) {
                        Task {
                            await model.decline(held, askedForJustNow: fresh)
                            turn = nil
                        }
                    }
                case .reserve, .cancel, .cancelPending, .failed:
                    Button(asked.isFailure ? "OK" : "キャンセル", role: .cancel) { turn = nil }
                }
            } message: { asked in
                switch asked {
                case .reserve(let device, let named):
                    let mode = device == .tv ? TVDriver.recordsIn : quality
                    Text("\(Format.dateTime.string(from: program.start)) \(program.serviceName)\n"
                         + "\(Codes.qualityLabel[mode] ?? mode) · "
                         + "\(Codes.repeatLabel[repeating] ?? repeating)"
                         + (named.map { " · " + model.diskLabel($0) } ?? "") + "\n"
                         + (device == .tv ? TVDriver.confirming : RecorderDriver.confirming(away: model.offline)))
                case .cancel(let reservation):
                    Text("\(Format.dateTime.string(from: reservation.start)) \(reservation.title)\n"
                         + "\(reservation.device.label)から削除されます。")
                case .cancelPending(let waiting):
                    Text("\(Format.dateTime.string(from: waiting.request.start)) \(waiting.request.title)\n"
                         + "この端末から削除し、\(waiting.target.label)には送りません。")
                case .failed(let said), .said(let said):
                    Text(said)
                case .kept(let why, _):
                    Text("\(Format.dateTime.string(from: program.start)) \(program.serviceName)\n" + why)
                case .wouldStop(let held, _):
                    // The reason without the sentence about a button this alert does not have. The consent
                    // is to the reason whole, as it stands on the row.
                    Text(TVDriver.asks(of: held) ?? held.problem ?? "")
                }
            }
            .onChange(of: done) { if $1 { dismiss() } }
        }
    }

    /// 削除 throughout, as in the rest of the app, and not 取り消す beside the dialog's own キャンセル.
    private var askTitle: String {
        switch ask {
        case .cancel: "この予約を削除しますか？"
        case .cancelPending: "送信待ちの予約を削除しますか？"
        case .failed: "エラー"
        case .kept(_, let stays): stays ? "送信待ちのままです" : "送信待ちにしました"
        case .said: "テレビの予約"
        case .wouldStop: "それでも予約しますか？"
        case .reserve(.recorder, _) where model.offline: RecorderDriver.keepingTitle
        case .reserve, nil: "この番組を録画予約しますか？"
        }
    }

    /// What has the recorder asked again what a reservation would clash with. It says whether 録画予約 is
    /// the television's, so that the recorder is asked when the section becomes its own again, and only
    /// that of the device: with the recorder alone it is what it was. The disk is in it, so that the clashes
    /// asked are the ones on the disk the row under 録画先 shows, and none while that is a disk let go of.
    private var taskKey: String {
        "\(program.id)-\(quality)-\(repeating)-\(checkedDisk ?? "")-\(checks)" + (device == .tv ? "-tv" : "")
    }

    /// 予約する: a reservation on `device`, sent with the disk the question named, or the internal disk where it
    /// named none. The mode and the repeat are read now, as the question showed them, and not when the request
    /// sets out. A disk that cannot be had -- no longer offered, or not answered by the slot while it was waited
    /// for -- is refused by the recorder's driver before anything is queued or sent, and the sheet goes back to
    /// the internal disk, named, with the television beside it under 予約先 where it is free.
    private func reserve(on device: DeviceSlot, disk named: String?) {
        let (quality, repeating) = (quality, repeating)
        let sent = named ?? RecorderDisk.internalID
        request(under: device == .tv ? TVDriver.reservingLine : nil, fresh: true) {
            let came = await model.reserve(program, on: device, quality: quality, repeating: repeating, disk: sent)
            if model.diskCannotBeHad(sent) { chosenDisk = RecorderDisk.internalID }
            return came
        }
    }

    /// What this sheet asks for a reservation: one on a device, a waiting row sent again, or the yes to
    /// making one all the same. What it came to is said (`say`), and with nothing put up and the sheet
    /// staying, 録画予約 is read afresh. `line` is for a request to the television, and is up for as long
    /// as that is out (`asking`). With no line it is the recorder's, and counted while it is out (`others`).
    private func request(under line: String? = nil, fresh: Bool,
                         _ work: @escaping @MainActor () async -> Reserved?) {
        asking = line
        if line == nil { others += 1 }
        Task {
            let came = await work()
            asking = nil
            if line == nil { others -= 1 }
            say(came, fresh: fresh)
            if ask == nil, !done { turn = nil }
        }
    }

    /// What a reservation, or a waiting row sent again, came to, as this sheet says it and what it does
    /// then: a case of the result to a case of the alert. `fresh` is a reservation asked for just now, on
    /// this sheet, and not a row that was waiting before: it travels with the question whether to make it
    /// all the same, however often that is asked again.
    ///
    /// Made closes the sheet, after what there is to say of it. Kept closes it too, the row then being on
    /// the reservations tab -- but not over a row that was waiting before, nor over one that carries a
    /// reason which is not what is being said (`Reserved.leftForTheReader`): that row was not sent at all,
    /// and waits for the reader whatever its device does next, so the sheet is left open on its section.
    /// Nil is nothing to say: the sections say what became of the row.
    private func say(_ came: Reserved?, fresh: Bool) {
        guard let came else { return }
        switch came {
        case .made(nil): done = true
        case .made(let more?): ask = .said(more)
        case .wouldStop(let held): ask = .wouldStop(held, fresh: fresh)
        case .waiting(_, let why): ask = .kept(why, stays: !fresh || came.leftForTheReader)
        case .notDone(let why): ask = .failed(why)
        }
    }

    /// 録画予約 for the television: the one mode it records in and the repeats it is sent for this
    /// programme. Nothing is said of what the reservation would stop, which the television is asked when
    /// the reader reserves and not before. Held back by the television's work, and by a request of this
    /// sheet's own that is still out (`others`): never by the recorder's work as such.
    private var televisionOffer: some View {
        Section("録画予約") {
            destinationRow(.tv)
            LabeledContent("録画モード", value: Codes.qualityLabel[TVDriver.recordsIn] ?? TVDriver.recordsIn)
            Picker("毎回録画", selection: $repeating) {
                ForEach(TVDriver.repeats(for: program), id: \.self) { key in
                    Text(Codes.repeatLabel[key] ?? key).tag(key)
                }
            }
            Button("録画予約する") { (turn, ask) = (.tv, .reserve(.tv, disk: nil)) }
                .disabled(model.isBusy(for: .tv) || others > 0)
        }
    }

    /// 予約先: where a new reservation goes, among the devices free for the programme. A choice with both
    /// free; one fixed line where a home's other device holds the programme or has it waiting; and nothing
    /// in a home with one device, where there is nothing to say.
    @ViewBuilder
    private func destinationRow(_ device: DeviceSlot) -> some View {
        let free = model.destinations(for: program)
        if free.count > 1 {
            Picker("予約先", selection: Binding(get: { device }, set: { chosen = $0 })) {
                ForEach(free, id: \.self) { Text($0.label).tag($0) }
            }
        } else if model.destinations.count > 1 {
            LabeledContent("予約先", value: device.label)
        }
    }

    /// The heading of a section that is about the recorder. With a television registered the sections are
    /// named for the device each is about -- レコーダー here, テレビ over the television's -- and what is in a
    /// section says the rest. With the recorder alone there is nothing to tell apart, and the heading says
    /// what it said before there was a television.
    private func heading(_ alone: String) -> String {
        model.tv != nil ? DeviceSlot.recorder.label : alone
    }

    /// The television's reservation of this programme, under the television's name: that it is there, the way
    /// to its own sheet to change it -- for as long as there is anything to change it to, which is the
    /// driver's to say (`TVDriver.repeats(changing:)`) -- and the way to delete it. Changing it happens on that
    /// sheet, as for the recorder's, and the way there is held back while a request of this sheet's own is
    /// out (`others`), as the television's other buttons here are. What went wrong with the television is said
    /// under the button that ran into it, and not at the sheet's foot, which is the recorder's.
    private func televisionSection(_ reservation: Reservation) -> some View {
        Section(DeviceSlot.tv.label) {
            LabeledContent("毎回録画", value: Codes.repeatLabel[reservation.repeatName ?? ""] ?? "しない")
            if reservation.recording { Text("録画中です").foregroundStyle(.red) }
            if !TVDriver.repeats(changing: reservation).isEmpty {
                Button("予約を変更する") { editing = reservation }
                    .disabled(others > 0)
            }
            Button("予約を削除", role: .destructive) { ask = .cancel(reservation) }
                .disabled(model.isBusy(for: .tv))
            if let problem = model.problem(for: .tv) {
                Text(problem).foregroundStyle(.red).font(.callout)
            }
        }
    }

    /// A reservation made while its device could not be reached. It shows what was asked for, since the
    /// device has not made anything of it yet, and what the device said if it refused. With a television
    /// saved there can be one for each device, each under its device's name, and what is said and held
    /// back in one goes by its own device: a television's row is neither sent again nor deleted while the
    /// television works, since a sending that is out may have it in hand. Nor is it sent again while
    /// another request of this sheet's is out (`others`).
    private func pendingSection(_ waiting: PendingReservation) -> some View {
        let device = waiting.target
        return Section(model.tv != nil ? "\(device.label)・送信待ち" : "この番組は送信待ちです") {
            LabeledContent("録画モード",
                           value: Codes.quality(code: waiting.request.qualityCode)
                               .map { Codes.qualityLabel[$0] ?? $0 } ?? "-")
            LabeledContent("毎回録画",
                           value: Codes.repeatLabel[Codes.repeatName(code: waiting.request.repeatCode) ?? ""]
                               ?? "しない")
            if let shown = model.diskShown(waiting) { LabeledContent("録画先", value: shown) }
            if let problem = waiting.problem {
                // Refused, and not sent again by itself: asking again gets the same answer until whatever
                // it names has changed, which only the reader can know.
                Text(problem).foregroundStyle(.red).font(.callout)
                Button("もう一度送る") {
                    request(under: device == .tv ? TVDriver.sendingLine : nil, fresh: false) {
                        await model.sendAgain(waiting)
                    }
                }
                .disabled(device == .tv ? model.isBusy(for: .tv) || others > 0 : model.working)
            } else {
                Text("\(device.label)に届いていない予約です。次に\(device.label)につながったときに登録します。")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Button("送信待ちの予約を削除", role: .destructive) { ask = .cancelPending(waiting) }
                .disabled(device == .tv && model.isBusy(for: .tv))
        }
    }

    /// What the recorder answers when asked what a new reservation would clash with: the reservations whose
    /// hours it shares (`docs/xsrs-api.md`). Said as that rather than as 重複, the recorder's own mark: it has
    /// more than one tuner, so hours in common do not by themselves mean anything will be missed.
    @ViewBuilder
    private var conflictRow: some View {
        if checking {
            HStack {
                ProgressView().controlSize(.small)
                Text("時間が重なる予約を確認中").foregroundStyle(.secondary)
            }
        } else if let conflicts {
            if conflicts.isEmpty {
                Label(RecorderDriver.noClashes, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("時間が重なる予約が \(conflicts.count) 件あります", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.legibleOrange)
                        .font(.callout)
                    ForEach(conflicts) { conflict in
                        Text("\(Format.dateTime.string(from: conflict.start)) \(conflict.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Only where 録画予約 is the recorder's: nothing is asked of the recorder on account of a reservation
    /// that goes to the television. Nor for a disk let go of (`checkedDisk`), whose row then shows nothing: the
    /// clashes said before were for a disk that is no longer the one shown. A USB disk the slot did not answer
    /// while it was waited for is said by the model, and the sheet goes back to the internal disk, asked afresh.
    private func check() async {
        guard device == .recorder, !past else { return }
        guard let disk = checkedDisk else {
            (conflicts, checking) = (nil, false)
            return
        }
        guard model.connected else { return }
        checking = true
        let found = await model.conflicts(for: program, quality: quality, repeating: repeating, disk: disk)
        // A check that set out before the row changed comes back all the same (the recorder's requests are
        // not given up halfway), and what it found is for what the row showed then.
        guard !Task.isCancelled else { return }
        conflicts = found
        checking = false
        if found == nil, model.diskCannotBeHad(disk) { chosenDisk = RecorderDisk.internalID }
    }
}
