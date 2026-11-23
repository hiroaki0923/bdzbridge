import Foundation

/// The words the reservations' list and the recordings' list say alike, for each screen to lay out: the button of a
/// row's swipe that deletes it, the heading of the menu that sorts, the mark of a row that is being recorded and the
/// first choice of a menu that narrows. What only one of the lists says is that list's state's
/// (`ReservationsState`, `RecordingsState`).
public enum ListWords {
    public static let deleteLabel = "削除"
    public static let sortHeading = "並び順"
    public static let recordingMark = "録画中"
    public static let allLabel = "すべて"
}
