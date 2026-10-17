import Foundation

/// Every name the app keeps something under in UserDefaults, in one place.
///
/// Some are read in more than one file -- the runs with no screen read the address and the MAC the screens
/// write -- where a slip on either side reads nothing, without a word. They are names on the reader's phone
/// rather than in the code: renaming one forgets whatever was saved under it. The UI tests and the screenshots
/// set several as launch arguments (`-startTab guide`) and spell them out there, since that is another target.
enum DefaultsKey {
    // MARK: - the recorder

    /// Its address. Written whenever it changes and again whenever the recorder answers there, and read by
    /// the overnight run, which has no screen to ask.
    static let recorderHost = "recorderHost"
    /// Its wired MAC, for waking it. See `RecorderHost.remember(mac:)`.
    static let recorderMac = "recorderMac"
    /// The address the recorder was at when it reported the MAC. See `RecorderDriver.findElsewhere`.
    static let recorderMacHost = "recorderMacHost"
    /// What the runs with no screen have told of it (`ToldOnce`, in the recorder's words), as JSON: the stop told
    /// last, which for a recorder is another one answering, and the reservations warned of as not having
    /// reached it in time. Read and written by the overnight run and the Shortcuts action
    /// (`BackgroundWork.refreshTheRecorderNow`, `sendWaiting()`), whether or not a notification could be heard;
    /// written by the screens once none of the reservations warned of waits to go
    /// (`AppModel.forgetTheRecordersWarningOnceSent`); forgotten when the cache is made over to another recorder
    /// (`RecorderHost.cacheMadeOver`).
    static let recorderTold = "recorderTold"

    // MARK: - the television

    /// Its address, written as the recorder's is. The registration that goes with it is in the Keychain
    /// (`KeychainTVCredentials`), not here.
    static let tvHost = "tvHost"
    /// The MAC it wakes on, which is what tells it from any other. Kept to recognise it, never to wake it.
    static let tvMac = "tvMac"
    /// What the runs with no screen have told of it (`ToldOnce`), as JSON; forgotten when a television is
    /// registered or taken away. The recorder's is kept apart from it (`recorderTold`).
    static let tvTold = "tvTold"

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

    /// When the overnight run last fetched a guide. Shown on the settings screen, so that something invisible
    /// can still be seen to be working. Written by a run that still has its time and whose cache is still its
    /// recorder's, when a broadcasting type answered. This and the two marks below go with the cache when it
    /// is made over to another recorder.
    static let lastBackgroundRefresh = "lastBackgroundRefresh"
    /// Whether the low-space warning has been given since the disk last had room. See `Notify.lowSpace`.
    static let warnedLowSpace = "warnedLowSpace"
    /// The same for the disk in the recorder's USB slot, as which disk was warned about (`RecorderDisk.identity`),
    /// so that another disk in the slot has not been. See `Notify.lowSpace(on:)`.
    static let warnedLowSpaceOnUSB = "warnedLowSpaceOnUSB"

    // MARK: - the demo

    /// Also the name of the launch argument (`-demoData 1`), which is how the screenshots turn it on.
    static let demoData = "demoData"
    /// See `DemoData.banner`.
    static let demoBanner = "demoBanner"
    /// Where the real recorder's address and MAC are kept while the demo has the screen.
    static let hostBeforeDemo = "hostBeforeDemo"
    static let macBeforeDemo = "macBeforeDemo"
}
