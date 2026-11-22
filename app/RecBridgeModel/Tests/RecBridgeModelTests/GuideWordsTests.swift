import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// The guide's words as the screen has always said them, byte for byte (`GuideWords`), and the heading's name for no
/// station picked (`AppModel.channelName`). What VoiceOver reads of a programme on the air (`spoken(mark:at:)`) is held
/// in `GuideGridTests`.
@MainActor
final class GuideWordsTests: XCTestCase {
    func testTheGuideSaysWhatTheScreenSaid() {
        XCTAssertEqual(GuideWords.nowLabel, "今")
        XCTAssertEqual(GuideWords.previousDayLabel, "前の日")
        XCTAssertEqual(GuideWords.nextDayLabel, "次の日")
        XCTAssertEqual(GuideWords.allStationsLabel, "すべての局")
        XCTAssertEqual(GuideWords.showAllStationsLabel, "すべての局を表示")
        XCTAssertEqual(GuideWords.onAirLabel, "放送中")
        XCTAssertEqual(GuideWords.detailsPrefix, "詳細：")
        XCTAssertEqual(GuideWords.channelsLabel, "チャンネルの表示と並び順")
    }

    /// The way to the stations shown is called one thing, in the guide's menu, in the settings' row and as that
    /// screen's title.
    func testTheWayToTheStationsShownIsTheScreensTitle() {
        XCTAssertEqual(ChannelsState.title, "チャンネルの表示と並び順")
        XCTAssertEqual(GuideWords.channelsLabel, SettingsWords.channelsLabel)
        XCTAssertEqual(ChannelsState.title, SettingsWords.channelsLabel)
    }

    /// With no station picked, or one the list does not hold, the heading says every station.
    func testTheHeadingSaysEveryStationWhereNoneIsPicked() throws {
        let model = try aBench().modelWithNoRecorder()
        XCTAssertNil(model.serviceFilter)
        XCTAssertEqual(model.channelName, "すべての局")
        model.serviceFilter = 1_024
        XCTAssertEqual(model.channelName, "すべての局")
    }
}
