import Foundation
import RecorderKit

/// The words the sheets of a programme, a reservation and a recording say alike, for each sheet to lay out: the
/// labels of their rows, the headings of what is said of the programme, the line while a reservation is being
/// recorded and the button that deletes one, the buttons of the question before a delete and of a report, and how a
/// mode, a repeat and a reservation's repeat are worded. What only one sheet says is that sheet's state's. OK and
/// キャンセル are also those of the screens' alerts and questions that have none of their own, and 削除する that of the
/// lists' and a programme's page's question before one delete; 録画先 and ジャンル also head the recordings' menu that
/// narrows (`RecordingsState`).
public enum SheetWords {
    public static let station = "放送"
    public static let starts = "開始"
    public static let length = "長さ"
    public static let genre = "ジャンル"
    public static let quality = "録画モード"
    public static let repeating = "毎回録画"
    public static let disk = "録画先"

    /// The headings of the programme's summary and of the rest that is said of it.
    public static let summaryHeading = "番組内容"
    public static let detailsHeading = "詳細"

    /// Said in red while the reservation is being recorded.
    public static let recordingLine = "録画中です"
    public static let deleteReservationLabel = "予約を削除"

    /// The buttons of the question before a delete, 削除する and キャンセル, and the one of a report, OK.
    public static let confirmDeleteLabel = "削除する"
    public static let cancelLabel = "キャンセル"
    public static let okLabel = "OK"

    /// A mode in the words a picker offers it in (`Codes.qualityLabel`), or its name where the table has none: the
    /// sheets' pickers, and the settings' 既定の録画モード.
    public static func qualityLabel(_ name: String) -> String { Codes.qualityLabel[name] ?? name }

    /// A repeat in the words a picker offers it in (`Codes.repeatLabel`), or its name where the table has none.
    public static func repeatLabel(_ name: String) -> String { Codes.repeatLabel[name] ?? name }

    /// A reservation's repeat as its row says it: しない where its code is none the tables know.
    public static func repeatShown(_ reservation: Reservation) -> String {
        Codes.repeatLabel[reservation.repeatName ?? ""] ?? "しない"
    }
}
