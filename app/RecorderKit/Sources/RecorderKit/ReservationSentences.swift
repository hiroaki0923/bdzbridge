import Foundation

/// What the screens say of a reservation and of a row that waits: what deleting one does, who made one, and
/// whether one follows its programme.
public extension Reservation {
    /// What the question before a delete says it does, under the row's time and title: taken off its device, and,
    /// for one the recorder made by itself, that the recorder may make it again -- in the list's words when it is
    /// asked from the list (`fromTheList`), in the sheet's otherwise.
    @MainActor
    func whatDeletingDoes(fromTheList: Bool) -> String {
        "\(device.label)から削除されます。"
            + (createdByRecorder
               ? "\n" + (fromTheList ? RecorderDriver.mayComeBackFromTheList : RecorderDriver.mayComeBack) : "")
    }

    /// Who made it, as its sheet says under 登録元.
    var madeBy: String {
        createdByRecorder ? "レコーダー（おまかせ録画）" : createdByApp ? "アプリから" : "不明"
    }

    /// What its sheet says under 番組追従 of one made with the programme's event id, which the device follows when
    /// the programme moves; nil for one that is held to its time.
    var followsItsProgramme: String? {
        eventID == nil ? nil : "時間が変わっても追いかけます"
    }
}

public extension PendingReservation {
    /// What the question before a waiting row is deleted says it does, under the row's time and title.
    var whatDeletingDoes: String {
        "この端末から削除し、\(target.label)には送りません。"
    }
}
