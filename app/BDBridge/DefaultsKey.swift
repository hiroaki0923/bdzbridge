import Foundation

/// Every name the app keeps something under in UserDefaults, in one place.
///
/// Some are read in more than one file -- the overnight run reads the address and the MAC the screens
/// write -- and each file spelled them out for itself, where a slip on either side reads nothing, without a
/// word. They are names on the reader's phone rather than in the code: renaming one forgets whatever was
/// saved under it. The UI tests and the screenshots set several as launch arguments (`-startTab guide`) and
/// spell them out there, since that is another target.
enum DefaultsKey {
    // MARK: - the recorder

    /// Its address. Written whenever it changes and again whenever the recorder answers there, and read by
    /// the overnight run, which has no screen to ask.
    static let recorderHost = "recorderHost"
    /// Its wired MAC, for waking it. See `AppModel.remember(mac:)`.
    static let recorderMac = "recorderMac"
    /// The address the recorder was at when it reported the MAC. See `AppModel.macWasReadHere`.
    static let recorderMacHost = "recorderMacHost"

    // MARK: - what the screens keep between launches

    static let guideBroadcasting = "guideBroadcasting"
    static let guideMode = "guideMode"
    static let gridPointsPerMinute = "gridPointsPerMinute"
    static let reservationSort = "reservationSort"
    static let recordingsSort = "recordingsSort"
    static let recordingsMode = "recordingsMode"
    /// 既定の録画モード in the settings. The name the sheets used to write, so a mode picked in an earlier
    /// version is where it starts. See `DefaultQuality`.
    static let defaultQuality = "defaultQuality"

    // MARK: - set only from the command line, for the screenshots and for checking a screen in a simulator

    static let startTab = "startTab"
    /// The time of day the guide opens at instead of now, as `HH:mm`. See `GuideClock`.
    static let guideOpenAt = "guideOpenAt"
    static let searchFor = "searchFor"
    static let searchScope = "searchScope"

    // MARK: - the overnight run

    /// Shown on the settings screen, so that something invisible can still be seen to be working.
    static let lastBackgroundRefresh = "lastBackgroundRefresh"
    /// Whether the low-space warning has been given since the disk last had room. See `Notify.lowSpace`.
    static let warnedLowSpace = "warnedLowSpace"

    // MARK: - the demo

    /// Also the name of the launch argument (`-demoData 1`), which is how the screenshots turn it on.
    static let demoData = "demoData"
    /// See `DemoData.banner`.
    static let demoBanner = "demoBanner"
    /// Where the real recorder's address and MAC are kept while the demo has the screen.
    static let hostBeforeDemo = "hostBeforeDemo"
    static let macBeforeDemo = "macBeforeDemo"
}
