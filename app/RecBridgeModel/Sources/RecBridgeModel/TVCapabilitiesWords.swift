import Foundation

/// The words of the screen that says what the television speaks (`AppModel.tvCapabilities(at:)`), opened from the
/// television's part of the settings: its title, the button that reads it, what is said under that -- what is read,
/// that nothing changes, what the text leaves out, and what to do with it --, and the button that copies the text.
public enum TVCapabilitiesWords {
    public static let title = "テレビの対応状況"
    public static let checkLabel = "調べる"
    public static let footer = "テレビが対応している機能と、予約や録画の一覧を読めるかを調べます。読むだけで、"
        + "テレビの予約や設定は変わりません。結果に番組名や局名は含まれません。"
        + "うまく動かないときは、結果をコピーして、お問い合わせの際にお送りください。"
        + "テレビに予約と録画が 1 件ずつあると、より詳しく分かります。"
    public static let copyLabel = "コピー"
}
