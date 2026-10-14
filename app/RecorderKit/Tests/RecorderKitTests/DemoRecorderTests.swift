import Foundation
import RecorderKit
import XCTest

/// The demo's recorder by itself, through the client the app reads a real one with: what it says it is, the
/// reservations, the recordings and the keyword conditions it starts with, and what it does with what it is
/// told. The screens, the screenshots and the bench lean on all of it; this holds it field by field, as the
/// literals it answers today, so that the recorder can be read and moved with its answers kept.
///
/// Its lists are placed by the clock when it is made, on the broadcast day on air then. So nothing here reads the
/// clock: a row is found by its id, and its start is held as a time of day in Japan and a number of broadcast
/// days from the first weekly reservation's. The row being recorded started twenty minutes before the recorder
/// was made, which is a moment rather than a time of day, and its start is not held. It is kind where a real
/// recorder is not -- a delete or a change of something it does not hold, a protected recording or one being
/// recorded, all go through -- and that is held as it is.
final class DemoRecorderTests: XCTestCase {
    /// Nine in the evening in Japan on Sunday 1 November 2026: when a reservation made here is for.
    private static let evening = Date(timeIntervalSince1970: 1_793_534_400)

    private static let japan: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RecorderTime.timeZone
        return calendar
    }()

    private func client() -> RecorderClient {
        RecorderClient(host: "192.0.2.63", transport: DemoRecorder())
    }

    /// A time of day in Japan, to the second.
    private func clock(_ date: Date) -> String {
        let parts = Self.japan.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? -1, parts.minute ?? -1, parts.second ?? -1)
    }

    /// How many broadcast days `date`'s is after `first`'s.
    private func days(_ date: Date, after first: Date) -> Int {
        Self.japan.dateComponents([.day], from: GuideStore.broadcastDay(containing: first),
                                  to: GuideStore.broadcastDay(containing: date)).day ?? .min
    }

    /// A reservation as a test asks for one: an hour at nine in the evening on the first terrestrial station.
    private func request(quality: Int, minutes: Int = 60, programme: Int? = 0x1234) -> ReservationRequest {
        ReservationRequest(title: "テスト予約", start: Self.evening, durationSec: minutes * 60, repeatCode: "1",
                           broadcastingType: 2, serviceID: 1024, qualityCode: quality, eventID: programme)
    }

    /// A reservation's line: everything it says but its start and its repeat, which are held apart.
    private func line(_ row: Reservation) -> String {
        var flags: [String] = []
        if row.recording { flags.append("recording") }
        if row.conflict { flags.append("conflict") }
        return "\(row.id) \(row.title) \(row.serviceID)/\(row.broadcastingType) \(row.durationSec)s"
            + " q\(row.qualityCode) g\(row.genreCode.map(String.init) ?? "nil")"
            + " p\(row.eventID.map(String.init) ?? "nil") \(row.sizeMB.map(String.init) ?? "nil")MB"
            + " \(row.destination) by \(row.creator ?? "nil") [\(flags.joined(separator: ","))]"
    }

    /// A recording's line: everything it says but its start, which is held apart, and when it was last played,
    /// which is held against its start.
    private func line(_ row: RecordedTitle) -> String {
        var flags: [String] = []
        if row.isNew { flags.append("new") }
        if row.protected { flags.append("protected") }
        if row.recording { flags.append("recording") }
        return "\(row.id) \(row.title) \(row.serviceID)/\(row.broadcastingType) \(row.durationSec)s"
            + " q\(row.qualityCode) g\(row.genreCode.map(String.init) ?? "nil")"
            + " \(row.sizeMB.map(String.init) ?? "nil")MB \(row.destination) [\(flags.joined(separator: ","))]"
            + " resume \(row.resumeSec.map(String.init) ?? "nil")"
    }

    /// A keyword condition's line, every field of it.
    private func line(_ rule: RecorderRule) -> String {
        "\(rule.id) \(rule.name) \(rule.keywords) -\(rule.excluded) \(rule.logic)"
            + " g\(rule.genreLevel1.map(String.init) ?? "nil")/\(rule.genreLevel2.map(String.init) ?? "nil")"
            + " \(rule.timeScope) \(rule.broadcastingScope)"
            + " q\(rule.qualityCode.map(String.init) ?? "nil") 4K q\(rule.qualityCode4K.map(String.init) ?? "nil")"
            + " \(rule.destination)"
    }

    // MARK: - what it says it is

    /// It describes itself as the BDZ-FBT4100 it stands for, guide files and all, though it serves none: every
    /// guide file is a 404, which the client reads as none. It says its firmware, its own address and MAC, that
    /// it is on and playing nothing, that nothing clashes, that its USB slot holds no disk, and takes a playback.
    func testItSaysWhatItIs() async throws {
        let recorder = client()

        let described = try await recorder.describe()
        XCTAssertEqual([described.host, "\(described.port)", described.friendlyName, described.product, described.model,
                        described.udn, "\(described.epgCapable)", described.location, described.via],
                       ["192.0.2.63", "64220", "BDR - BDZ-FBT4100", "Sony-BDZ", "BDZ-202105",
                        "uuid:00000000-0000-0000-0000-000000000000", "true",
                        "http://192.0.2.63:64220/description.xml", "manual"])
        let firmware = try await recorder.firmwareVersion()
        XCTAssertEqual(firmware, "1.234")
        let network = try await recorder.networkSettings()
        XCTAssertEqual([network.mac, network.wireless, network.address, "\(network.usesDhcp)"],
                       ["f8:4e:17:00:00:00", "", "192.0.2.63", "true"])
        let power = try await recorder.powerOn()
        XCTAssertEqual(power, "on")
        let status = try await recorder.playStatus()
        XCTAssertEqual(status, ["playStatus": "stop"])
        let clashes = try await recorder.conflicts(elements: XsrsElements.create(request(quality: 220)))
        XCTAssertEqual(clashes, [])
        let usb = try await recorder.disk(RecorderDisk.usbID)
        XCTAssertNil(usb, "the demo's USB slot holds a disk")
        try await recorder.playControl(titleID: "0x0000000000008001", operation: "play")

        let file = try await DemoRecorder().send(HTTPRequest(url: try XCTUnwrap(
            URL(string: "http://192.0.2.63:60151//EPG_TRDEPG_FILE.dat"))))
        XCTAssertEqual(file.statusCode, 404)
        let guide = try await recorder.epgFile("td")
        XCTAssertNil(guide)
    }

    // MARK: - its reservations

    /// Eight reservations, in the order it lists them: the one being recorded now, three of this evening's (one
    /// weekly, one of its own おまかせ・まる録), three of tomorrow's (one weekly, and two at the same hours, one
    /// marked as clashing), and one on BS the day after. Each weekly one repeats on its own weekday.
    func testItsReservations() async throws {
        let rows = try await client().reservations()

        XCTAssertEqual(rows.map(line), [
            "0x00000000000a9431 サンプルニュース 1024/2 3600s q230 g0 p14113 3800MB HDD by 2200 [recording]",
            "0x00000000000a9432 サンプル劇場「ひかりの街」第５話 1024/2 2700s q220 g48 p1013 2900MB HDD by 2200 []",
            "0x00000000000a9433 みほんドキュメント　山の記憶 1024/2 3600s q100 g128 p1015 5900MB HDD by 2200 []",
            "0x00000000000b1101 サンプル音楽館　夏の特集 1024/2 3600s q220 g64 p1017 2700MB HDD by 1100 []",
            "0x00000000000a9434 サンプルアニメ　空色パズル（７） 1048/2 7200s q240 g112 p1106 1600MB HDD by 2200 []",
            "0x00000000000a9435 ひなたスポーツ特集 1064/2 7200s q220 g16 p1106 4200MB HDD by 2200 [conflict]",
            "0x00000000000a9436 みほんスポーツ中継「サンプルリーグ」 1056/2 7200s q220 g17 p1106 4300MB HDD by 2200 []",
            "0x00000000000b1102 BSサンプル劇場「星空紀行」 2048/3 7200s q220 g96 p1206 7400MB HDD by 1100 []",
        ])

        let first = try XCTUnwrap(rows.first { $0.id == "0x00000000000a9432" }).start
        XCTAssertEqual(rows.dropFirst().map { "\($0.id) \(clock($0.start)) +\(days($0.start, after: first))" }, [
            "0x00000000000a9432 20:00:00 +0",
            "0x00000000000a9433 21:00:00 +0",
            "0x00000000000b1101 22:30:00 +0",
            "0x00000000000a9434 16:00:00 +1",
            "0x00000000000a9435 18:00:00 +1",
            "0x00000000000a9436 18:00:00 +1",
            "0x00000000000b1102 20:00:00 +2",
        ])
        let sports = rows.filter { ["0x00000000000a9435", "0x00000000000a9436"].contains($0.id) }
        XCTAssertEqual(sports.count, 2)
        XCTAssertEqual(sports.first?.start, sports.last?.start, "the two that clash are not at the same moment")

        let weekly: Set = ["0x00000000000a9432", "0x00000000000a9434"]
        XCTAssertEqual(rows.map { Optional($0.repeatCode) }, rows.map {
            weekly.contains($0.id) ? Codes.repeatCodes[Codes.weekdayRepeat(for: $0.start)] : "1"
        })
    }

    // MARK: - what it is told about reservations

    /// A reservation made is listed under the next of its numbers, with what a recorder adds to what it was sent:
    /// no genre, no clash, the app as its maker, not recording, and a size for its length and mode. A change keeps
    /// its id and takes the new mode. A change rebuilds the row from what was sent, so one of its own おまかせ
    /// comes back as the app's, and a change of an id it does not hold makes a row of that id. A delete takes the
    /// row away, and a delete of an id it does not hold changes nothing.
    func testWhatItIsToldAboutReservations() async throws {
        let recorder = client()

        try await recorder.create(request(quality: 100))
        try await recorder.create(request(quality: 220, minutes: 30, programme: nil))
        var rows = try await recorder.reservations()
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(rows.suffix(2).map(line), [
            "0x000000000000af01 テスト予約 1024/2 3600s q100 g0 p4660 11400MB HDD by 2200 []",
            "0x000000000000af02 テスト予約 1024/2 1800s q220 g0 pnil 1800MB HDD by 2200 []",
        ])
        XCTAssertEqual(rows.suffix(2).map(\.start), [Self.evening, Self.evening])

        try await recorder.updateReservation(id: "0x000000000000af01", request(quality: 240))
        rows = try await recorder.reservations()
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(rows.filter { $0.id == "0x000000000000af01" }.map(line), [
            "0x000000000000af01 テスト予約 1024/2 3600s q240 g0 p4660 3600MB HDD by 2200 []",
        ])

        let own = try XCTUnwrap(rows.first { $0.id == "0x00000000000b1101" })
        try await recorder.updateReservation(id: own.id, ReservationRequest(
            title: own.title, start: own.start, durationSec: own.durationSec, repeatCode: own.repeatCode,
            broadcastingType: own.broadcastingType, serviceID: own.serviceID, qualityCode: 240,
            eventID: own.eventID))
        rows = try await recorder.reservations()
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(rows.filter { $0.id == "0x00000000000b1101" }.map(line), [
            "0x00000000000b1101 サンプル音楽館　夏の特集 1024/2 3600s q240 g0 p1017 3600MB HDD by 2200 []",
        ])

        try await recorder.updateReservation(id: "0x00000000000c0001", request(quality: 100))
        rows = try await recorder.reservations()
        XCTAssertEqual(rows.count, 11)
        XCTAssertEqual(rows.filter { $0.id == "0x00000000000c0001" }.map(line), [
            "0x00000000000c0001 テスト予約 1024/2 3600s q100 g0 p4660 11400MB HDD by 2200 []",
        ])

        try await recorder.deleteReservation(id: "0x00000000000a9433")
        rows = try await recorder.reservations()
        XCTAssertEqual(rows.count, 10)
        XCTAssertFalse(rows.contains { $0.id == "0x00000000000a9433" }, "a deleted reservation is still listed")

        let before = rows
        try await recorder.deleteReservation(id: "0x00000000000c0002")
        let after = try await recorder.reservations()
        XCTAssertEqual(after, before)
    }

    // MARK: - its recordings and its disk

    /// Twenty-two recordings, in the order it lists them: the one being written now, then a drama's four
    /// episodes, documentaries, an anime's, sport, music, a film and the rest, each with its station, mode,
    /// genre, size, flags and where playback stopped; one never played says when it was last played as nothing,
    /// and one played says a day after it was recorded.
    func testItsRecordings() async throws {
        let recorder = client()
        let rows = try await recorder.allTitles()

        XCTAssertEqual(rows.map(line), [
            "0x0000000000008000 サンプルニュース 1024/2 3600s q230 g0 760MB HDD [new,recording] resume 0",
            "0x0000000000008001 サンプル劇場「ひかりの街」第４話 1024/2 2700s q220 g48 2884MB HDD [new] resume 0",
            "0x0000000000008002 サンプル劇場「ひかりの街」第３話 1024/2 2700s q220 g48 2901MB HDD [protected] resume 0",
            "0x0000000000008003 サンプル劇場「ひかりの街」第２話 1024/2 2700s q220 g48 2877MB HDD [] resume 1240",
            "0x0000000000008004 サンプル劇場「ひかりの街」第１話 1024/2 3600s q220 g48 3810MB HDD [] resume 0",
            "0x0000000000008005 みほんドキュメント　海の記憶 1024/2 3600s q100 g128 11640MB HDD [new] resume 0",
            "0x0000000000008006 サンプルアニメ　空色パズル（６） 1048/2 7200s q240 g112 1562MB HDD [new] resume 0",
            "0x0000000000008007 サンプルアニメ　空色パズル（５） 1048/2 7200s q240 g112 1548MB HDD [] resume 0",
            "0x0000000000008008 サンプル映画劇場「遠い灯台」 1048/2 7200s q220 g96 7420MB HDD [] resume 3600",
            "0x0000000000008009 ひなたスポーツ特集　サンプルリーグ第１２節 1064/2 7200s q220 g16 6180MB HDD [new] resume 0",
            "0x000000000000800a サンプル音楽館　夏の特集 1024/2 3600s q220 g64 2640MB HDD [] resume 0",
            "0x000000000000800b BSサンプル劇場「星空紀行」 2048/3 7200s q220 g96 7380MB HDD [new] resume 0",
            "0x000000000000800c みほんクラシック館 1032/2 3600s q100 g65 10920MB HDD [] resume 0",
            "0x000000000000800d サンプルクイズ王 1040/2 3600s q240 g81 890MB HDD [new] resume 0",
            "0x000000000000800e みほん自然紀行 1032/2 7200s q220 g130 5940MB HDD [] resume 2400",
            "0x000000000000800f サンプル旅番組「各駅停車」 1048/2 7200s q240 g177 1720MB HDD [] resume 0",
            "0x0000000000008010 サンプルアニメ　空色パズル（４） 1048/2 7200s q240 g112 1551MB HDD [] resume 0",
            "0x0000000000008011 サンプルアニメ　空色パズル（３） 1048/2 7200s q240 g112 1544MB HDD [] resume 0",
            "0x0000000000008012 みほんドキュメント　川の記憶 1024/2 3600s q100 g128 11580MB HDD [] resume 900",
            "0x0000000000008013 みほんドキュメント　町の記憶 1024/2 3600s q100 g128 11610MB HDD [] resume 0",
            "0x0000000000008014 ひなたスポーツ特集　サンプルリーグ第１１節 1064/2 7200s q220 g16 6120MB HDD [] resume 0",
            "0x0000000000008015 ひなたスポーツ特集　サンプルリーグ第１０節 1064/2 7200s q220 g16 6090MB HDD [] resume 0",
        ])

        let reservations = try await recorder.reservations()
        let first = try XCTUnwrap(reservations.first { $0.id == "0x00000000000a9432" }).start
        XCTAssertEqual(rows.dropFirst().map { "\($0.id) \(clock($0.start)) \(days($0.start, after: first))" }, [
            "0x0000000000008001 20:00:00 -1",
            "0x0000000000008002 20:00:00 -8",
            "0x0000000000008003 20:00:00 -15",
            "0x0000000000008004 20:00:00 -22",
            "0x0000000000008005 21:00:00 -2",
            "0x0000000000008006 16:00:00 -2",
            "0x0000000000008007 16:00:00 -9",
            "0x0000000000008008 19:00:00 -3",
            "0x0000000000008009 18:00:00 -4",
            "0x000000000000800a 22:30:00 -5",
            "0x000000000000800b 20:00:00 -6",
            "0x000000000000800c 21:00:00 -7",
            "0x000000000000800d 18:00:00 -7",
            "0x000000000000800e 18:00:00 -10",
            "0x000000000000800f 10:00:00 -11",
            "0x0000000000008010 16:00:00 -16",
            "0x0000000000008011 16:00:00 -23",
            "0x0000000000008012 21:00:00 -9",
            "0x0000000000008013 21:00:00 -16",
            "0x0000000000008014 18:00:00 -11",
            "0x0000000000008015 18:00:00 -18",
        ])
        let played: Set = ["0x0000000000008002", "0x0000000000008003", "0x0000000000008004", "0x0000000000008007",
                           "0x0000000000008008", "0x000000000000800a", "0x000000000000800c", "0x000000000000800e",
                           "0x000000000000800f", "0x0000000000008010", "0x0000000000008011", "0x0000000000008012",
                           "0x0000000000008013", "0x0000000000008014", "0x0000000000008015"]
        XCTAssertEqual(rows.map(\.lastPlayed), rows.map {
            played.contains($0.id) ? $0.start.addingTimeInterval(86_400) : nil
        })
    }

    /// The disk is two terabytes, and what is free is what the recordings and a fixed share of other things
    /// leave: the same whichever disk is asked about. A deleted recording gives its size back. A protected one
    /// and the one being recorded are deleted all the same, and a delete of an id it does not hold changes
    /// nothing.
    func testItsDiskAndWhatADeleteDoes() async throws {
        let recorder = client()

        var disk = try await recorder.recordDestinationInfo()
        XCTAssertEqual(disk.totalBytes, 2_000_000_000_000)
        XCTAssertEqual(disk.freeBytes, 490_433_000_000)
        disk = try await recorder.recordDestinationInfo(destination: "USBHDD")
        XCTAssertEqual(disk.totalBytes, 2_000_000_000_000)
        XCTAssertEqual(disk.freeBytes, 490_433_000_000)

        try await recorder.deleteTitle(id: "0x0000000000008005")
        var rows = try await recorder.allTitles()
        XCTAssertEqual(rows.count, 21)
        XCTAssertFalse(rows.contains { $0.id == "0x0000000000008005" }, "a deleted recording is still listed")
        disk = try await recorder.recordDestinationInfo()
        XCTAssertEqual(disk.totalBytes, 2_000_000_000_000)
        XCTAssertEqual(disk.freeBytes, 502_073_000_000)

        try await recorder.deleteTitle(id: "0x0000000000008002")
        try await recorder.deleteTitle(id: "0x0000000000008000")
        rows = try await recorder.allTitles()
        XCTAssertEqual(rows.count, 19)
        XCTAssertFalse(rows.contains { ["0x0000000000008002", "0x0000000000008000"].contains($0.id) },
                       "a protected recording or the one being recorded is still listed after its delete")

        let before = rows
        try await recorder.deleteTitle(id: "0x0000000000009999")
        let after = try await recorder.allTitles()
        XCTAssertEqual(after, before)
    }

    /// A rename, a protect and the new flag each land on the recording they name and change nothing else; a
    /// change of an id it does not hold changes nothing. Every recording's details are the same invented text.
    func testWhatItIsToldAboutRecordings() async throws {
        let recorder = client()
        let before = try await recorder.allTitles()

        try await recorder.updateTitle(id: "0x0000000000008003", title: "サンプル劇場　改題", protected: true,
                                       isNew: true)
        try await recorder.updateTitle(id: "0x0000000000008001", isNew: false)
        try await recorder.updateTitle(id: "0x0000000000009999", title: "どこにもない", protected: true)
        let after = try await recorder.allTitles()
        var expected = before
        let renamed = try XCTUnwrap(expected.firstIndex { $0.id == "0x0000000000008003" })
        expected[renamed].title = "サンプル劇場　改題"
        expected[renamed].protected = true
        expected[renamed].isNew = true
        let seen = try XCTUnwrap(expected.firstIndex { $0.id == "0x0000000000008001" })
        expected[seen].isNew = false
        XCTAssertEqual(after, expected)

        for id in ["0x0000000000008001", "0x0000000000009999"] {
            let detail = try await recorder.titleDetail(id: id)
            XCTAssertEqual(detail.summary, "これはサンプルの番組情報です。実在の番組・人物とは関係ありません。")
            XCTAssertEqual(detail.details, ["出演　サンプル太郎、みほん花子"])
        }
    }

    // MARK: - its keyword conditions

    /// Three keyword conditions of its own, every field of them. One made is answered with the next of the one
    /// numbering its reservations take theirs from, and listed -- with no id, as what the client sends carries
    /// none for the recorder to put the new one in, so a delete by the id it answered leaves it there. A delete
    /// takes one of its own away, and a delete of an id it does not hold changes nothing.
    func testItsKeywordConditions() async throws {
        let recorder = client()

        var rules = try await recorder.recorderRules()
        XCTAssertEqual(rules.map(line), [
            "0x0000470f サンプル劇場 [\"サンプル劇場\", \"ひかりの街\"] -[\"再放送\"] OR g3/0 NIGHT TRD q220 4K qnil HDD",
            "0x0000570b 空色パズル [\"空色パズル\"] -[] OR g7/nil ALL ALL q240 4K q240 HDD",
            "0x00021703 みほん/紀行 [\"みほん\", \"紀行\"] -[] AND g8/2 ALL BSD q100 4K qnil HDD",
        ])

        try await recorder.create(request(quality: 220))
        let id = try await recorder.createRecorderRule(RecorderRuleRequest(keywords: ["テスト"], qualityCode: 220))
        XCTAssertEqual(id, "0x0000af02")
        rules = try await recorder.recorderRules()
        XCTAssertEqual(rules.count, 4)
        XCTAssertEqual(rules.last.map(line), " テスト [\"テスト\"] -[] OR gnil/nil ALL ALL q220 4K q220 HDD")
        try await recorder.deleteRecorderRule(id: id)
        rules = try await recorder.recorderRules()
        XCTAssertEqual(rules.count, 4)

        try await recorder.deleteRecorderRule(id: "0x0000470f")
        rules = try await recorder.recorderRules()
        XCTAssertEqual(rules.count, 3)
        XCTAssertFalse(rules.contains { $0.id == "0x0000470f" }, "a deleted condition is still listed")

        let before = rules
        try await recorder.deleteRecorderRule(id: "0x00009999")
        let after = try await recorder.recorderRules()
        XCTAssertEqual(after, before)
    }
}
