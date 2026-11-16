import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// The television's part of the settings in the words the screen has always said, byte for byte (`TVSettingsState`),
/// and the small rules of what it says: what the television says of itself, the helper's value, and what is said with
/// no television, in the demo and out of it.
@MainActor
final class TVWordsTests: XCTestCase {
    func testTheTelevisionsPartSaysWhatTheScreenSaid() {
        XCTAssertEqual(TVSettingsState.heading, "テレビ")
        XCTAssertEqual(TVSettingsState.modelLabel, "機種")
        XCTAssertEqual(TVSettingsState.hostLabel, "IP アドレス")
        XCTAssertEqual(TVSettingsState.standingLabel, "状態")
        XCTAssertEqual(TVSettingsState.capabilitiesLabel, "対応状況を調べる")
        XCTAssertEqual(TVSettingsState.storageLabel, "USB ハードディスク")
        XCTAssertEqual(TVSettingsState.registerLabel, "登録する")
        XCTAssertEqual(TVSettingsState.reconnectLabel, "再接続")
        XCTAssertEqual(TVSettingsState.helperLabel, "番組表（ヘルパー）")
        XCTAssertEqual(TVSettingsState.forgetHelperLabel, "ヘルパーの登録を解除")
        XCTAssertEqual(TVSettingsState.registerHelperLabel, "ヘルパーに登録")
        XCTAssertEqual(TVSettingsState.removeLabel, "テレビを外す")
        XCTAssertEqual(TVSettingsState.removalQuestion, "テレビを外しますか？")
        XCTAssertEqual(TVSettingsState.confirmRemovingLabel, "外す")
        XCTAssertEqual(TVSettingsState.addLabel, "アドレスを入力して追加")
    }

    /// What is said under the part with no television: in the demo, that the invented one can be added and goes with
    /// the demo; out of it, the two ways to add one and the number its screen shows.
    func testWhatIsSaidWithNoTelevisionFollowsTheDemo() {
        XCTAssertEqual(TVSettingsState.noTelevisionFooter(inDemo: true),
                       "サンプルデータでは、架空のテレビを追加して試せます。"
                       + "サンプルを終了すると、架空のテレビも消えます。")
        XCTAssertEqual(TVSettingsState.noTelevisionFooter(inDemo: false),
                       "テレビは、「レコーダーとテレビを探す」で探せます。見つからないときは、テレビの IP アドレスを"
                       + "入力して追加できます。登録のときに、テレビの画面に表示される 4 桁の番号を入力します。")
    }

    /// What the television says of itself, as the part says it: nothing with no television, and once one is
    /// connected, its model as it gave it and its USB disk in the words the recorder's disks share, both sizes said.
    func testTheTelevisionsModelAndDiskAreSaidAsItGaveThem() async throws {
        let empty = try aBench()
        let none = TVSettingsState(model: empty.modelWithNoRecorder())
        XCTAssertNil(none.modelName)
        XCTAssertNil(none.storageLine)

        let bench = try aBench()
        let television = DemoTV(power: "active")
        let credentials = await registered(with: television)
        let model = bench.modelWithNoRecorder(television: television, credentials: credentials)
        await model.start()
        try await untilTheTelevisionIsConnected(model)
        try await until("the television's disk was never read") { model.tvDriver?.facts.storage != nil }
        let settings = TVSettingsState(model: model)
        XCTAssertEqual(settings.modelName, DemoTV.model)
        let storage = try XCTUnwrap(model.tvDriver?.facts.storage)
        XCTAssertEqual(settings.storageLine, Format.storage(mounted: storage.mounted, freeBytes: storage.freeBytes,
                                                           totalBytes: storage.totalBytes, on: .tv))
        XCTAssertTrue(settings.storageLine?.hasPrefix("残り ") == true, "the disk's sizes were not said")
    }

    /// 番組表（ヘルパー） says whether the app holds a registration with the helper.
    func testTheHelpersValueSaysWhetherTheAppIsRegistered() throws {
        let bench = try aBench()
        let model = bench.modelWithNoRecorder()
        let settings = TVSettingsState(model: model)
        XCTAssertEqual(settings.helperShown, "未登録")
        model.tvHelper = helper(token: "token")
        XCTAssertEqual(settings.helperShown, "登録済み")
        model.tvHelper = helper(token: nil)
        XCTAssertEqual(settings.helperShown, "未登録")
    }

    /// A helper at an address reserved for documentation, which nothing here asks: registered with when it holds a
    /// token.
    private func helper(token: String?) -> TVHelperGuide {
        TVHelperGuide(client: TVHelperClient(host: Bench.tvHost, transport: SilentRecorder(),
                                             tokens: MemoryTVHelperToken(token)))
    }
}
