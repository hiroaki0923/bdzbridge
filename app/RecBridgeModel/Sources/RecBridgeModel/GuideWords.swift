import Foundation

/// The words of the guide's screen and of a programme's row that are typed in no state of their own, for the screen
/// to lay out: the menu item that goes to now and the two arrows beside the day, the choice of every station and the
/// button that shows them again, the word on a programme that is on the air, the front of the line the search puts
/// under a programme found only in its details, and the way to which stations the guide shows.
public enum GuideWords {
    public static let nowLabel = "今"
    public static let previousDayLabel = "前の日"
    public static let nextDayLabel = "次の日"

    /// What the heading says, and the picker offers, with no station picked; and the button that picks none again when
    /// the one picked leaves nothing to show.
    public static let allStationsLabel = "すべての局"
    public static let showAllStationsLabel = "すべての局を表示"

    /// Said of a programme that is on the air, in its row and in what VoiceOver reads of it.
    public static let onAirLabel = "放送中"

    /// The front of the line the search puts under a programme found only in its details, before the words found and
    /// what is on either side of them.
    public static let detailsPrefix = "詳細："

    /// The way to which stations the guide shows and in what order, called as the settings call it.
    public static let channelsLabel = SettingsWords.channelsLabel
}
