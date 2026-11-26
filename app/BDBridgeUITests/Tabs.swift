import XCTest

/// The app's tabs, by the tag each has in `RootView`.
enum AppTab: String {
    case guide, search, reservations, recordings, settings

    /// The name on the tab.
    var name: String {
        switch self {
        case .guide: "番組表"
        case .search: "検索"
        case .reservations: "予約"
        case .recordings: "録画"
        case .settings: "設定"
        }
    }
}

/// Whether the tests run on an iPad, where some of them go another way or do not apply. Read on the main thread,
/// where XCTest runs the UI tests.
var onAnIPad: Bool { MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .pad } }

extension XCUIApplication {
    /// A tab's button, to tap. An iPhone's tabs are a tab bar's buttons, found by their names. An iPad's, from
    /// iPadOS 26, are buttons in the window's bar with no tab bar around them, where a name is not theirs alone --
    /// the search's scope 予約 is a button too -- so they are found by the identifier the app gives each, which an
    /// iPhone's tab bar leaves out.
    func tab(_ tab: AppTab) -> XCUIElement {
        onAnIPad ? buttons.matching(identifier: "tab-" + tab.rawValue).firstMatch : tabBars.buttons[tab.name]
    }
}
