import RecorderKit
import SwiftUI

/// One reservation as the device that holds it has it -- the recorder, or the television -- with the way to
/// undo it.
///
/// This does not go through the guide, so it works for a reservation whose programme has dropped out of the
/// eight days the recorder publishes, and for one that records by time only.
///
/// A television's is shown, changed and deleted. What can be changed is its repeat, until its programme
/// begins, to what its driver offers (`TVDriver.repeats(changing:)`): the sheet has no rule of its own, and
/// offers nothing the change's door would turn away. A recorder's is offered the modes and the repeats its
/// driver lists (`RecorderDriver.recordsIn`, `repeats(startingAt:)`), and what the sheet says of one in words
/// of the recorder's is its driver's too. What the change came to is said in the sheet's one alert,
/// under the device's name when something is to be added to a change made. While a request of the sheet's own
/// to the television is out, the change or the delete, its line is on the sheet, nothing on it can be
/// pressed and the sheet cannot be closed: what the request came to is said here, and a sheet that had gone
/// would say it nowhere. The recorder's rows are not held so. Whatever is held back, said in red or reported
/// as a failure is the row's own device's, and the other device's work and trouble are left out of it.
struct ReservationSheet: View {
    let reservation: Reservation
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var confirming = false
    @State private var failure: String?
    @State private var program: GuideProgramRow?
    @State private var done = false
    /// What the pickers hold, seeded from the recorder and compared against it to know whether to offer 変更.
    @State private var quality = ""
    @State private var repeating = ""
    /// The disk the reader moved it to, nil while it is left on its own, kept as picked: a move to a disk let
    /// go of since is refused when it is sent, not sent to another. Moved back, it is nil again, so that what
    /// the recorder holds it on is kept (`RecorderDriver.update`).
    @State private var movedTo: String?
    @State private var saved = false
    /// A change made, and what its device added to it, said before the sheet closes.
    @State private var said: String?
    /// A change of the recorder's not sent because the disk it goes to cannot be had: its report leaves the
    /// sheet open, the sentence asking for another disk on this sheet's picker, which offers what is left.
    @State private var anotherDiskWanted = false
    /// The line of a request of this sheet's own to the television, while it is out. Never set for the
    /// recorder.
    @State private var asking: String?

    private var past: Bool { reservation.end <= Date() }
    private var onTelevision: Bool { reservation.device == .tv }

    /// What a recorder's row can be given, as its driver offers them: the weekly one only on the programme's own
    /// weekday (`RecorderDriver.repeats(startingAt:)`).
    private var repeatOptions: [String] { RecorderDriver.repeats(startingAt: reservation.start) }

    /// What a television's row can be changed to, the row's own repeat among them: none once its programme
    /// has begun, and none for a repeat that has no name here.
    private var televisionsRepeats: [String] { TVDriver.repeats(changing: reservation) }

    /// For a television's row, only the repeat, and only while it has a picker: the one mode it records in is
    /// no choice made. For the recorder's, any of its pickers.
    private var changed: Bool {
        onTelevision
            ? !televisionsRepeats.isEmpty && repeating != (reservation.repeatName ?? "none")
            : quality != (reservation.qualityName ?? "") || repeating != (reservation.repeatName ?? "none")
                || movedTo != nil
    }

    /// The disks it can be moved between, while it can still be changed: none for a television's row, and none
    /// in a home with no USB disk, where no picker is drawn.
    private var diskChoices: [RecorderDisk] {
        past || reservation.recording ? [] : model.diskChoices(for: reservation)
    }

    var body: some View {
        NavigationStack {
            List {
                // A television is never woken, so the recorder's waking is nothing to a row of its own.
                if !onTelevision { WakingSection() }
                Section {
                    Text(reservation.title).font(.headline)
                    LabeledContent("放送", value: model.channelName(for: reservation))
                    LabeledContent("開始", value: Format.dateTime.string(from: reservation.start))
                    LabeledContent("長さ", value: Format.duration(reservation.durationSec))
                    if onTelevision {
                        televisionsValues
                    } else {
                        recordersValues
                    }
                }

                if reservation.recording || reservation.conflict || reservation.createdByRecorder {
                    Section {
                        if reservation.recording { Text("録画中です").foregroundStyle(.red) }
                        if reservation.conflict { conflictRow }
                        if reservation.createdByRecorder {
                            Text(RecorderDriver.madeByItself)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let program, !program.summary.isEmpty {
                    Section("番組内容") { Text(program.summary) }
                }
                if let program, !program.extended.isEmpty {
                    Section("詳細") { Text(program.extended) }
                }

                if let asking {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(asking).font(.callout)
                        }
                    }
                }

                if changed {
                    Section {
                        Button("変更を\(reservation.device.label)に送る") { sendTheChange() }
                            .disabled(model.isBusy(for: reservation.device))
                    } footer: {
                        Text(onTelevision
                             ? TVDriver.changesTheRepeatOnly
                             : RecorderDriver.changeFooter(followsItsProgramme: reservation.eventID != nil,
                                                           offersADisk: !diskChoices.isEmpty))
                    }
                }

                // 削除, the word the list's swipe and every other delete in the app use: 取り消す would stand
                // beside キャンセル in the dialog, two words for going back on something.
                Section {
                    Button("予約を削除", role: .destructive) { confirming = true }
                        .disabled(model.isBusy(for: reservation.device))
                }

                if let problem = model.problem(for: reservation.device) {
                    Section { Text(problem).foregroundStyle(.red).font(.callout) }
                }
            }
            .disabled(asking != nil)
            .navigationTitle("予約")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseButton().disabled(asking != nil) }
            .interactiveDismissDisabled(asking != nil)
            .task {
                quality = reservation.qualityName ?? RecorderDriver.recordsIn.first ?? "LSR"
                repeating = reservation.repeatName ?? "none"
                program = await model.program(for: reservation)
            }
            .onChange(of: saved) { if $1 { dismiss() } }
            // One alert, because two on the same view is not something SwiftUI promises to honour, and
            // asking and reporting never happen at once. The red line further up the sheet was missed.
            .alert(alertTitle,
                   isPresented: Binding(get: { confirming || failure != nil || said != nil },
                                        set: { if !$0 { alertClosed() } })) {
                if failure == nil, said == nil {
                    Button("削除する", role: .destructive) {
                        if onTelevision { asking = TVDriver.deletingLine }
                        Task {
                            done = await model.cancel(reservation)
                            asking = nil
                            if !done { failure = whatWentWrong }
                        }
                    }
                    Button("キャンセル", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: {
                if let failure {
                    Text(failure)
                } else if let said {
                    Text(said)
                } else {
                    Text("\(Format.dateTime.string(from: reservation.start)) \(reservation.title)\n"
                         + "\(reservation.device.label)から削除されます。"
                         + (reservation.createdByRecorder ? "\n" + RecorderDriver.mayComeBack : ""))
                }
            }
            .onChange(of: done) { if $1 { dismiss() } }
            .closesWithItsDevice(reservation.device)
        }
    }

    /// The one alert's title: what went wrong, what a change made added under the name of the device that
    /// holds the row, or the question before a delete.
    private var alertTitle: String {
        failure != nil ? "エラー" : said != nil ? "\(reservation.device.label)の予約" : "この予約を削除しますか？"
    }

    /// The alert has been closed, whichever it was. The report of a failed change or delete takes the sheet
    /// with it, for either device's row: the list was read again on the way, and the row this sheet holds may
    /// no longer be the device's as it holds it, so trying again starts from the list -- but for a change of
    /// the recorder's not sent because the disk it goes to cannot be had, whose sentence asks for another disk
    /// on this sheet (`anotherDiskWanted`). What a change made added takes the sheet with it as well, as a
    /// change made with nothing to add does at once. Looked at here and not in the button, before the report
    /// is cleared: closing the alert is what clears it.
    private func alertClosed() {
        if failure != nil, !anotherDiskWanted { done = true }
        if said != nil { done = true }
        confirming = false
        failure = nil
        said = nil
        anotherDiskWanted = false
    }

    /// 変更を〈機器〉に送る: the change goes to the device that holds the row, with what the pickers hold as it
    /// is pressed, and what it came to is said. Made with nothing to add closes the sheet; made with something
    /// to add says it, and closing that closes the sheet; not made says why, and closing that closes the sheet
    /// too, unless the disk the change goes to cannot be had (`alertClosed`). A request to the television holds
    /// the sheet open until it is answered (`asking`).
    private func sendTheChange() {
        let moved = movedTo
        if onTelevision { asking = TVDriver.changingLine }
        Task {
            let altered = await model.change(reservation, quality: quality, repeating: repeating, disk: moved)
            asking = nil
            switch altered {
            case .done(nil): saved = true
            case .done(let more?): said = more
            case .notDone(let why):
                failure = why
                // By why the change was not sent, not by whether the reservation's own disk is offered now: a
                // disk moved to that is not offered, or the slot answering no disk for the disk it went to.
                let notOffered = moved.map { !RecorderDisk.offers($0, with: model.usbDisk) } ?? false
                anotherDiskWanted = !onTelevision
                    && (notOffered || model.diskNotHad == (moved ?? reservation.destination))
            }
            // A move to a disk that cannot be had -- no longer offered, or not answered by the slot while it was
            // waited for -- is forgotten: the reservation stays where the recorder holds it, and the picker offers
            // what is left.
            if let moved, model.diskCannotBeHad(moved) { movedTo = nil }
        }
    }

    /// What a delete that failed is reported as: the line of the row's device, which is where its delete
    /// says what went wrong.
    private var whatWentWrong: String {
        model.problem(for: reservation.device) ?? "\(reservation.device.label)がエラーを返しました"
    }

    /// What the recorder holds of it beyond the times, and the choices that can still be changed: the mode, the
    /// repeat, and the disk where there is one to move it to.
    @ViewBuilder
    private var recordersValues: some View {
        if past || reservation.recording {
            LabeledContent("録画モード", value: Codes.qualityLabel[reservation.qualityName ?? ""]
                           ?? reservation.qualityName ?? "-")
            LabeledContent("毎回録画", value: Codes.repeatLabel[reservation.repeatName ?? ""] ?? "しない")
        } else {
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
        }
        diskRow
        if reservation.eventID != nil {
            LabeledContent("番組追従", value: "時間が変わっても追いかけます")
        }
        LabeledContent("登録元", value: reservation.createdByRecorder ? "レコーダー（おまかせ録画）"
                       : reservation.createdByApp ? "アプリから" : "不明")
        if let size = reservation.sizeMB {
            LabeledContent("録画サイズ", value: String(format: "%.1f GB", Double(size) / 1024))
        }
    }

    /// 録画先: a picker beside the mode and the repeat while there is a disk to move it between, which a
    /// reservation off the internal disk always has once its own is not offered -- the internal disk, and its
    /// own. Otherwise its disk as a value: the one moved to, still named once it is no longer offered, or its
    /// own when that is off the internal disk. Nothing in a home with no USB disk.
    @ViewBuilder
    private var diskRow: some View {
        let offered = diskChoices
        if !offered.isEmpty {
            Picker("録画先", selection: Binding(get: { movedTo ?? reservation.destination },
                                               set: { movedTo = $0 == reservation.destination ? nil : $0 })) {
                ForEach(offered, id: \.destination) { choice in
                    Text(RecorderDisk.label(choice.destination, named: choice.name)).tag(choice.destination)
                }
            }
        } else if let shown = movedTo.map(model.diskLabel) ?? model.diskShown(reservation) {
            LabeledContent("録画先", value: shown)
        }
    }

    /// What a television's row says of how it records: the mode as a value, only when the row carries one,
    /// which a television's need not; and the repeat, a picker over what it can be changed to while there is
    /// anything, and otherwise a value. Who made it and how large it will be a television's row does not say,
    /// and that a reservation goes after its programme when the times change is known of the recorder only.
    @ViewBuilder
    private var televisionsValues: some View {
        if let quality = reservation.qualityName {
            LabeledContent("録画モード", value: Codes.qualityLabel[quality] ?? quality)
        }
        let offered = televisionsRepeats
        if offered.isEmpty {
            LabeledContent("毎回録画", value: Codes.repeatLabel[reservation.repeatName ?? ""] ?? "しない")
        } else {
            Picker("毎回録画", selection: $repeating) {
                ForEach(offered, id: \.self) { key in
                    Text(Codes.repeatLabel[key] ?? key).tag(key)
                }
            }
        }
    }

    /// The recorder's 重複, and the reservations at the same hours, by when, where and what: the recorder does
    /// not say which one it clashes with. See `AppModel.overlapping`.
    private var conflictRow: some View {
        let others = model.overlapping(reservation)
        return VStack(alignment: .leading, spacing: 4) {
            Text("他の予約と重複しています").foregroundStyle(Color.legibleOrange)
            if others.isEmpty {
                Text("読み込んだ予約一覧には、時間が重なる予約がありません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("時間が重なる予約").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(others) { other in
                    Text("\(Format.dateTime.string(from: other.start))〜\(Format.time.string(from: other.end))"
                         + "　\(model.channelName(for: other))　\(other.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .rowLinesInFull()
    }
}
