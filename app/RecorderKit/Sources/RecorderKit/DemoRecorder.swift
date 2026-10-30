import Foundation

/// An invented BDZ-FBT4100: a recorder that is not there, made of canned answers. It is how the App Store
/// screenshots are taken, it is what the tutorial offers to anyone without a recorder to hand, and the app's
/// tests stand on it.
///
/// It is not a mock of the app. The answers are the XML a BDZ-FBT4100 really sends, parsed by the code that
/// parses the real thing. Everything in it is invented: the reservations, the recordings, the keyword
/// conditions, the address and the MAC; the reservations and the recordings are made from the invented
/// stations and their days (`DemoLineUp`), so the guide can mark what it holds.
///
/// It answers the app's requests out of its own lists, made from the line-up, and remembers what is done
/// to it. The remembering is the point: a demo where 録画予約する says yes and the reservation never appears
/// in the list looks broken. So a reservation made here is added to the list, a changed one is changed, a
/// deleted one goes, and the same for recordings and for the keyword conditions.
///
/// It is kinder than the real one, where `DemoTV` is not: it answers as done a delete or a change of a
/// reservation it does not hold, which the real one answers with 804, and the delete of a protected recording
/// or of one being recorded, which the real one refuses with 820 or a bare 500 (`docs/porting.md`,
/// `docs/xsrs-api.md`). It also takes as done a change of a recording and a delete of a keyword condition it
/// does not hold, where what the real one answers has not been tried; a delete of a recording it does not hold,
/// the real one answers as done too. The screens never send these to it -- they read the list and check
/// first -- and a test that needs the real refusal scripts it in its own wrapper. The television's driver is
/// tested on `DemoTV`, so a kinder answer there would hide a fault; the recorder's driver is tested on scripted
/// answers and on vectors from real captures, so nothing of the app's or the driver's stands on this one's
/// kindness: only the demo does, and the tests that hold this recorder itself, as it is.
///
/// The demo gives it a USB disk (`usbDisk`), as invented as the rest, so that what a home with one is shown can
/// be seen without one. The disk is described in the slot as a real one is, and its recordings are listed only
/// for the slot's criteria, as a real recorder lists them. Made without it, as the tests make it, it answers
/// the slot with nothing, which is a home with no USB disk.
///
/// It is an actor because the app's client sends from wherever it likes, and this holds state.
public actor DemoRecorder: HTTPTransport {
    public static let host = "192.0.2.63"          // reserved for documentation (RFC 5737): never a real host
    public static let mac = "f8:4e:17:00:00:00"    // Sony's OUI, the rest zeroed, as everywhere else in this repo
    static let firmware = "1.234"
    public static let totalBytes = 2_000_000_000_000
    /// The invented USB disk's name, its size in the recorder's MB and when it was registered.
    static let usbName = "サンプルディスク"
    static let usbTotalMB = 1_000_000
    static let usbRegistered = "2026-01-02T03:04:05+0900"

    private let usbDisk: Bool
    private var reservations = DemoRecorder.reservationItems
    /// The recordings of both disks, each saying which it is on.
    private var titles: [String]
    private var rules = DemoRecorder.ruleObjects
    private var nextID = 0xaf00
    /// How long each answer takes: the demo's pace, which the app gives it, nothing in a test unless it needs the
    /// moment between a request and its answer.
    private let delay: Duration

    /// It starts with its lists full -- the reservations, the recordings and the keyword conditions the demo
    /// shows -- since the demo and every test that makes one take it as it is; `DemoTV` starts with nothing it
    /// is not given, since its tests build their own.
    public init(delay: Duration = .zero, usbDisk: Bool = false) {
        self.delay = delay
        self.usbDisk = usbDisk
        titles = DemoRecorder.titleItems + (usbDisk ? DemoRecorder.usbTitleItems : [])
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if delay > .zero { try? await Task.sleep(for: delay) }

        if request.url.path == "/description.xml" {
            return HTTPResponse(statusCode: 200, body: Data(DemoRecorder.descriptionXml.utf8))
        }
        guard request.method == "POST" else {
            // A guide file: there is none. The cache was filled directly, and 404 is what a recorder that
            // has not built its files yet answers, which the app reads as nothing to fetch.
            return HTTPResponse(statusCode: 404)
        }

        let body = (try? XmlNode.parse(request.body ?? Data()))
        func argument(_ name: String) -> String {
            body?.firstDescendantText(name) ?? ""
        }

        switch action(of: request) {
        // MARK: reservations
        case "X_GetRecordScheduleList":
            return soap(result: DemoRecorder.wrap(reservations), totalMatches: reservations.count)
        case "X_GetConflictList":
            return soap(result: "")
        case "X_CreateRecordSchedule":
            let id = takeID()
            reservations.append(DemoRecorder.reservationItem(fromElements: argument("Elements"), id: id))
            return soap(inner: "<RecordScheduleID>\(id)</RecordScheduleID>")
        case "X_UpdateRecordSchedule":
            let elements = argument("Elements")
            let id = DemoRecorder.id(in: elements)
            reservations.removeAll { DemoRecorder.id(in: $0) == id }
            reservations.append(DemoRecorder.reservationItem(fromElements: elements, id: id))
            return soap(inner: "")
        case "X_DeleteRecordSchedule":
            let id = argument("RecordScheduleID")
            reservations.removeAll { DemoRecorder.id(in: $0) == id }
            return soap(inner: "")

        // MARK: recordings
        case "X_GetTitleList":
            // No criteria is the internal disk's list, and the slot's is asked for by its id.
            let onTheSlot = argument("SearchCriteria").contains(RecorderDisk.usbID)
            let listed = titles.filter { DemoRecorder.isOnTheSlot($0) == onTheSlot }
            return soap(result: DemoRecorder.wrap(listed), totalMatches: listed.count)
        case "X_DeleteTitle":
            let id = argument("TitleID")
            titles.removeAll { DemoRecorder.id(in: $0) == id }
            return soap(inner: "")
        case "X_UpdateTitle":
            let elements = argument("Elements")
            let id = DemoRecorder.id(in: elements)
            if let index = titles.firstIndex(where: { DemoRecorder.id(in: $0) == id }) {
                titles[index] = DemoRecorder.patch(titles[index], with: elements)
            }
            return soap(inner: "")
        case "X_GetTitleDetail":
            return soap(result: "<detail><summary>これはサンプルの番組情報です。"
                        + "実在の番組・人物とは関係ありません。</summary>"
                        + "<detail1>出演　サンプル太郎、みほん花子</detail1></detail>")

        // MARK: the recorder's own keyword conditions
        case "X_GetPrefRecSettingList":
            return soap(result: DemoRecorder.wrap(rules))
        case "X_CreatePrefRecSetting":
            let id = String(format: "0x%08x", takeNumber())
            rules.append(DemoRecorder.ruleObject(fromElements: argument("Elements"), id: id))
            return soap(inner: "<SearchSettingID>\(id)</SearchSettingID>")
        case "X_DeletePrefRecSetting":
            let id = argument("SearchSettingID")
            rules.removeAll { DemoRecorder.id(in: $0) == id }
            return soap(inner: "")

        // MARK: the box itself
        case "X_GetFirmwareVersion":
            return soap(result: "<firmware><version>\(DemoRecorder.firmware)</version></firmware>")
        case "X_GetPrivateIp":
            return soap(result: "<network><macAddress>\(DemoRecorder.mac)</macAddress>"
                        + "<wirelessMacAddress></wirelessMacAddress>"
                        + "<ipAddress>\(DemoRecorder.host)</ipAddress><useDhcp>1</useDhcp></network>")
        case "X_GetPlayStatus":
            return soap(result: "<status><playStatus>stop</playStatus></status>")
        case "X_PowerControl":
            return soap(result: "<power><powerstatus>on</powerstatus></power>")
        case "X_GetMediaInfo" where usbDisk && argument("recordDestinationID") == RecorderDisk.usbID:
            return soap(result: DemoRecorder.wrap(["<name>\(DemoRecorder.usbName)</name><mount>1</mount>"
                + "<remain>\(usbFreeMB)</remain><total>\(DemoRecorder.usbTotalMB)</total>"
                + "<registeredTime>\(DemoRecorder.usbRegistered)</registeredTime>"
                + "<recordableRemain>\(usbFreeMB)</recordableRemain>"]))
        case "X_HDLnkGetRecordDestinationInfo":
            let info = "<recordDestinationInfo totalCapacity=\"\(DemoRecorder.totalBytes)\" "
                + "availableCapacity=\"\(free)\" />"
            return soap(result: info, element: "RecordDestinationInfo")
        default:
            // Playback on a television that is not there, and anything else: accepted, nothing to say.
            return soap(inner: "")
        }
    }

    /// The free space, which grows as recordings are deleted here, because a demo that deletes six hours of
    /// television and reports the same free space as before is telling a small lie.
    private var free: Int {
        let used = titles.filter { !DemoRecorder.isOnTheSlot($0) }.reduce(0) { $0 + DemoRecorder.sizeMB(in: $1) }
        return max(0, DemoRecorder.totalBytes - used * 1_000_000 - DemoRecorder.otherUseBytes)
    }

    /// The same for the USB disk, in the recorder's MB, as the slot says it.
    private var usbFreeMB: Int {
        let used = titles.filter(DemoRecorder.isOnTheSlot).reduce(0) { $0 + DemoRecorder.sizeMB(in: $1) }
        return max(0, DemoRecorder.usbTotalMB - used - DemoRecorder.usbOtherUseMB)
    }

    private func takeID() -> String {
        String(format: "0x%016x", takeNumber())
    }

    private func takeNumber() -> Int {
        nextID += 1
        return nextID
    }

    /// The action, from the `SOAPAction` header the client sends.
    private func action(of request: HTTPRequest) -> String {
        let header = request.headers.first { $0.key.lowercased() == "soapaction" }?.value ?? ""
        return String(header.split(separator: "#").last ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    private func soap(result: String, totalMatches: Int? = nil, element: String = "Result") -> HTTPResponse {
        var inner = "<\(element)>\(Soap.escape(result))</\(element)>"
        if let totalMatches { inner += "<TotalMatches>\(totalMatches)</TotalMatches>" }
        return soap(inner: inner)
    }

    private func soap(inner: String) -> HTTPResponse {
        let body = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">"
            + "<s:Body><u:Response xmlns:u=\"\(Upnp.xsrsService)\">\(inner)</u:Response></s:Body></s:Envelope>"
        return HTTPResponse(statusCode: 200, body: Data(body.utf8))
    }
}

extension DemoRecorder {
    // MARK: - what the recorder is going to record

    /// One reservation to build out of the guide. When it is on, how long it runs, its genre and its
    /// programme id all come from the programme itself, so the two lists cannot drift apart.
    private struct Booked {
        var id: String
        var title: String
        var station: Int
        var dayOffset = 0
        var broadcastingType = 2
        var quality: Int
        var weekly = false
        var conflict = false
        var creator = "2200"
        var size: Int
    }

    private static let booked = [
        Booked(id: "0x00000000000a9432", title: "サンプル劇場「ひかりの街」第５話", station: 1024,
               quality: 220, weekly: true, size: 2900),
        Booked(id: "0x00000000000a9433", title: "みほんドキュメント　山の記憶", station: 1024,
               quality: 100, size: 5900),
        // The recorder's own おまかせ・まる録 puts its reservations in the same list, under its own creator id.
        // 1100, as a real recorder writes it: with anything else the list has no おまかせ in it.
        Booked(id: "0x00000000000b1101", title: "サンプル音楽館　夏の特集", station: 1024,
               quality: 220, creator: "1100", size: 2700),
        Booked(id: "0x00000000000a9434", title: "サンプルアニメ　空色パズル（７）", station: 1048,
               dayOffset: 1, quality: 240, weekly: true, size: 1600),
        // Marked 重複 by the recorder, with another reservation at the same hours for its sheet to name.
        Booked(id: "0x00000000000a9435", title: "ひなたスポーツ特集", station: 1064,
               dayOffset: 1, quality: 220, conflict: true, size: 4200),
        Booked(id: "0x00000000000a9436", title: "みほんスポーツ中継「サンプルリーグ」", station: 1056,
               dayOffset: 1, quality: 220, size: 4300),
        Booked(id: "0x00000000000b1102", title: "BSサンプル劇場「星空紀行」", station: 2048,
               dayOffset: 2, broadcastingType: 3, quality: 220, creator: "1100", size: 7400),
    ]

    private static var reservationItems: [String] {
        // The one being recorded now. It is the only one with no programme behind it: it started twenty
        // minutes ago, which is a time rather than a slot in the guide.
        var xml = [reservation(id: "0x00000000000a9431", title: "サンプルニュース",
                               start: Date().addingTimeInterval(-20 * 60), minutes: 60, service: 1024,
                               eventID: 0x3721, quality: 230, genre: 0, recording: true, size: 3800)]
        for booked in booked {
            guard let found = DemoLineUp.slot(booked.title, at: booked.station, dayOffset: booked.dayOffset) else {
                continue
            }
            xml.append(reservation(id: booked.id, title: booked.title, start: found.start,
                                   minutes: found.minutes, service: booked.station,
                                   broadcastingType: booked.broadcastingType, eventID: found.eventID,
                                   quality: booked.quality, genre: found.genre,
                                   repeatCode: booked.weekly ? weekly(found.start) : "1",
                                   conflict: booked.conflict, creator: booked.creator, size: booked.size))
        }
        return xml
    }

    // swiftlint:disable:next function_parameter_count
    private static func reservation(id: String, title: String, start: Date, minutes: Int, service: Int,
                                    broadcastingType: Int = 2, eventID: Int, quality: Int, genre: Int,
                                    repeatCode: String = "1", recording: Bool = false,
                                    conflict: Bool = false, creator: String = "2200",
                                    size: Int) -> String {
        "<item id=\"\(id)\"><title>\(Soap.escape(title))</title>"
            + "<scheduledStartDateTime>\(RecorderTime.format(start))</scheduledStartDateTime>"
            + "<scheduledDuration>\(minutes * 60)</scheduledDuration>"
            + "<scheduledConditionID>\(repeatCode)</scheduledConditionID>"
            + "<scheduledChannelID broadcastingType=\"\(broadcastingType)\" channelType=\"2\">"
            + String(format: "0x%04x", service) + "</scheduledChannelID>"
            + "<desiredMatchingID type=\"SI_PROGRAMID\">,,0x0," + String(format: "0x%04x", eventID)
            + "</desiredMatchingID>"
            + "<desiredQualityMode>\(quality)</desiredQualityMode>"
            + "<genreID type=\"2\">\(genre)</genreID>"
            + "<conflictID>\(conflict ? 1 : 0)</conflictID><mediaRemainAlertID>0</mediaRemainAlertID>"
            + "<reservationCreatorID>\(creator)</reservationCreatorID>"
            + "<recordingFlag>\(recording ? 1 : 0)</recordingFlag>"
            + "<recordDestinationID>HDD</recordDestinationID><recordSize>\(size)</recordSize></item>"
    }

    /// The weekly repeat code for the day a programme falls on. The recorder refuses any other weekday.
    private static func weekly(_ start: Date) -> String {
        Codes.repeatCodes[Codes.weekdayRepeat(for: start)] ?? "1"
    }

    // MARK: - what is on the disk

    private static var titleItems: [String] {
        var xml: [String] = []
        // The one being written to now, which is why it cannot be deleted. It is the same programme as the
        // reservation marked 録画中, because that is how it looks on a real recorder.
        xml.append(title(0x8000, "サンプルニュース", Date().addingTimeInterval(-20 * 60), 60, 1024,
                         quality: 230, genre: 0, size: 760, isNew: true, recording: true))
        xml.append(title(0x8001, "サンプル劇場「ひかりの街」第４話", DemoLineUp.moment("20:00", dayOffset: -1), 45, 1024,
                     quality: 220, genre: 48, size: 2884, isNew: true))
        xml.append(title(0x8002, "サンプル劇場「ひかりの街」第３話", DemoLineUp.moment("20:00", dayOffset: -8), 45, 1024,
                     quality: 220, genre: 48, size: 2901, protected: true, resume: 0))
        xml.append(title(0x8003, "サンプル劇場「ひかりの街」第２話", DemoLineUp.moment("20:00", dayOffset: -15), 45, 1024,
                     quality: 220, genre: 48, size: 2877, resume: 1_240))
        xml.append(title(0x8004, "サンプル劇場「ひかりの街」第１話", DemoLineUp.moment("20:00", dayOffset: -22), 60, 1024,
                     quality: 220, genre: 48, size: 3810, resume: 0))
        xml.append(title(0x8005, "みほんドキュメント　海の記憶", DemoLineUp.moment("21:00", dayOffset: -2), 60, 1024,
                     quality: 100, genre: 128, size: 11_640, isNew: true))
        xml.append(title(0x8006, "サンプルアニメ　空色パズル（６）", DemoLineUp.moment("16:00", dayOffset: -2), 120, 1048,
                     quality: 240, genre: 112, size: 1_562, isNew: true))
        xml.append(title(0x8007, "サンプルアニメ　空色パズル（５）", DemoLineUp.moment("16:00", dayOffset: -9), 120, 1048,
                     quality: 240, genre: 112, size: 1_548, resume: 0))
        xml.append(title(0x8008, "サンプル映画劇場「遠い灯台」", DemoLineUp.moment("19:00", dayOffset: -3), 120, 1048,
                     quality: 220, genre: 96, size: 7_420, resume: 3_600))
        xml.append(title(0x8009, "ひなたスポーツ特集　サンプルリーグ第１２節", DemoLineUp.moment("18:00", dayOffset: -4),
                     120, 1064, quality: 220, genre: 16, size: 6_180, isNew: true))
        xml.append(title(0x800a, "サンプル音楽館　夏の特集", DemoLineUp.moment("22:30", dayOffset: -5), 60, 1024,
                     quality: 220, genre: 64, size: 2_640, resume: 0))
        xml.append(title(0x800b, "BSサンプル劇場「星空紀行」", DemoLineUp.moment("20:00", dayOffset: -6), 120, 2048,
                     broadcastingType: 3, quality: 220, genre: 96, size: 7_380, isNew: true))
        xml.append(title(0x800c, "みほんクラシック館", DemoLineUp.moment("21:00", dayOffset: -7), 60, 1032,
                     quality: 100, genre: 65, size: 10_920, resume: 0))
        xml.append(title(0x800d, "サンプルクイズ王", DemoLineUp.moment("18:00", dayOffset: -7), 60, 1040,
                     quality: 240, genre: 81, size: 890, isNew: true))
        xml.append(title(0x800e, "みほん自然紀行", DemoLineUp.moment("18:00", dayOffset: -10), 120, 1032,
                     quality: 220, genre: 130, size: 5_940, resume: 2_400))
        xml.append(title(0x800f, "サンプル旅番組「各駅停車」", DemoLineUp.moment("10:00", dayOffset: -11), 120, 1048,
                     quality: 240, genre: 177, size: 1_720, resume: 0))
        xml.append(title(0x8010, "サンプルアニメ　空色パズル（４）", DemoLineUp.moment("16:00", dayOffset: -16), 120, 1048,
                     quality: 240, genre: 112, size: 1_551, resume: 0))
        xml.append(title(0x8011, "サンプルアニメ　空色パズル（３）", DemoLineUp.moment("16:00", dayOffset: -23), 120, 1048,
                     quality: 240, genre: 112, size: 1_544, resume: 0))
        xml.append(title(0x8012, "みほんドキュメント　川の記憶", DemoLineUp.moment("21:00", dayOffset: -9), 60, 1024,
                     quality: 100, genre: 128, size: 11_580, resume: 900))
        xml.append(title(0x8013, "みほんドキュメント　町の記憶", DemoLineUp.moment("21:00", dayOffset: -16), 60, 1024,
                     quality: 100, genre: 128, size: 11_610, resume: 0))
        xml.append(title(0x8014, "ひなたスポーツ特集　サンプルリーグ第１１節", DemoLineUp.moment("18:00", dayOffset: -11),
                     120, 1064, quality: 220, genre: 16, size: 6_120, resume: 0))
        xml.append(title(0x8015, "ひなたスポーツ特集　サンプルリーグ第１０節", DemoLineUp.moment("18:00", dayOffset: -18),
                     120, 1064, quality: 220, genre: 16, size: 6_090, resume: 0))
        return xml
    }

    /// What is on the USB disk: older episodes of a programme the internal disk holds too, programmes of its own,
    /// and a copy of one of the internal disk's. The ids as a BDZ-FBT4100 numbers the disk's recordings, which is
    /// `0x0002` where the internal disk has `0x0000`.
    private static var usbTitleItems: [String] {
        let usb = RecorderDisk.usbID
        return [
            title(0x0002_0100_0000_8100, "サンプルアニメ　空色パズル（２）", DemoLineUp.moment("16:00", dayOffset: -30), 120,
                  1048, quality: 240, genre: 112, size: 1_546, resume: 0, on: usb),
            title(0x0002_0100_0000_8101, "サンプルアニメ　空色パズル（１）", DemoLineUp.moment("16:00", dayOffset: -37), 120,
                  1048, quality: 240, genre: 112, size: 1_539, resume: 0, on: usb),
            title(0x0002_0100_0000_8102, "BS名画サンプル", DemoLineUp.moment("10:00", dayOffset: -20), 180, 2048,
                  broadcastingType: 3, quality: 100, genre: 96, size: 20_310, protected: true, resume: 0, on: usb),
            title(0x0002_0100_0000_8103, "みほんドキュメント　森の記憶", DemoLineUp.moment("21:00", dayOffset: -23), 60, 1024,
                  quality: 100, genre: 128, size: 11_500, isNew: true, on: usb),
            title(0x0002_0100_0000_8104, "サンプル音楽館　夏の特集", DemoLineUp.moment("22:30", dayOffset: -12), 60, 1024,
                  quality: 220, genre: 64, size: 2_650, resume: 1_800, on: usb),
        ]
    }

    private static func title(_ number: Int, _ name: String, _ start: Date, _ minutes: Int, _ service: Int,
                              broadcastingType: Int = 2, quality: Int, genre: Int, size: Int,
                              protected: Bool = false, isNew: Bool = false, resume: Int? = nil,
                              recording: Bool = false, on destination: String = RecorderDisk.internalID) -> String {
        let played: String
        if let resume {
            played = "<lastPlaybackTime resumePoint=\"\(resume)\">"
                + RecorderTime.format(start.addingTimeInterval(86_400)) + "</lastPlaybackTime>"
        } else {
            played = "<lastPlaybackTime resumePoint=\"0\">notplayed</lastPlaybackTime>"
        }
        return "<item id=\"" + String(format: "0x%016llx", number) + "\">"
            + "<title>\(Soap.escape(name))</title>"
            + "<scheduledStartDateTime>\(RecorderTime.format(start))</scheduledStartDateTime>"
            + "<scheduledDuration>\(minutes * 60)</scheduledDuration>"
            + "<scheduledChannelID broadcastingType=\"\(broadcastingType)\" channelType=\"2\">"
            + String(format: "0x%04x", service) + "</scheduledChannelID>"
            + "<desiredQualityMode>\(quality)</desiredQualityMode>"
            + "<genreID type=\"2\">\(genre)</genreID>"
            + "<titleProtectFlag>\(protected ? 1 : 0)</titleProtectFlag>"
            + "<titleNewFlag>\(isNew ? 1 : 0)</titleNewFlag>"
            + "<recordingFlag>\(recording ? 1 : 0)</recordingFlag>"
            + "<recordDestinationID>\(destination)</recordDestinationID>"
            + "<recordSize>\(size)</recordSize>" + played + "</item>"
    }

    // MARK: - the recorder's own keyword conditions

    private static let ruleObjects: [String] = [
        """
        <object type="SEARCH" id="0x0000470f"><desiredQualityMode>220</desiredQualityMode>\
        <recordDestinationID>HDD</recordDestinationID>\
        <searchSetting type="MULTIPLE" logic="OR"><name>サンプル劇場</name>\
        <genreID type="2">0x30</genreID><keyword>サンプル劇場</keyword><keyword>ひかりの街</keyword>\
        <excludeKeyword>再放送</excludeKeyword>\
        <timeScope>NIGHT</timeScope><broadcastTypeScope>TRD</broadcastTypeScope></searchSetting></object>
        """,
        """
        <object type="SEARCH" id="0x0000570b"><desiredQualityMode>240</desiredQualityMode>\
        <desiredQualityModeForAdvanced>240</desiredQualityModeForAdvanced>\
        <recordDestinationID>HDD</recordDestinationID>\
        <searchSetting type="MULTIPLE" logic="OR"><name>空色パズル</name>\
        <genreID type="3">0x7*</genreID><keyword>空色パズル</keyword>\
        <timeScope>ALL</timeScope><broadcastTypeScope>ALL</broadcastTypeScope></searchSetting></object>
        """,
        """
        <object type="SEARCH" id="0x00021703"><desiredQualityMode>100</desiredQualityMode>\
        <recordDestinationID>HDD</recordDestinationID>\
        <searchSetting type="MULTIPLE" logic="AND"><name>みほん/紀行</name>\
        <genreID type="2">0x82</genreID><keyword>みほん</keyword><keyword>紀行</keyword>\
        <timeScope>ALL</timeScope><broadcastTypeScope>BSD</broadcastTypeScope></searchSetting></object>
        """,
    ]

    // MARK: - keeping a list, so that what the reader does to the demo sticks

    /// What the recorder wraps a list in.
    private static func wrap(_ items: [String]) -> String {
        "<xsrs xmlns=\"\(Upnp.xsrsMetadataNamespace)\">" + items.joined() + "</xsrs>"
    }

    /// Roughly how much of the disk is taken by things this demo does not list, so that the free space moves
    /// with what is deleted but does not start at the whole disk.
    private static let otherUseBytes = 1_400_000_000_000
    private static let usbOtherUseMB = 400_000

    private static func isOnTheSlot(_ title: String) -> Bool {
        title.contains("<recordDestinationID>\(RecorderDisk.usbID)</recordDestinationID>")
    }

    /// The `id` attribute of the element a fragment starts with.
    private static func id(in xml: String) -> String {
        guard let quote = xml.range(of: "id=\"") else { return "" }
        return String(xml[quote.upperBound...].prefix { $0 != "\"" })
    }

    private static func sizeMB(in item: String) -> Int {
        Int((try? XmlNode.parse(item))?.childText("recordSize") ?? "") ?? 0
    }

    /// A list item for a reservation the app has just made, built out of the very XML it sent. A recorder
    /// answers the list with fields of its own added to what it was given, and so does this.
    private static func reservationItem(fromElements elements: String, id newID: String) -> String {
        guard let item = element("item", in: elements) else { return "" }
        var made = setting(id: newID, in: item)
        if !made.contains("<genreID") { made = adding("<genreID type=\"2\">0</genreID>", to: made) }
        if !made.contains("<conflictID") { made = adding("<conflictID>0</conflictID>", to: made) }
        if !made.contains("<reservationCreatorID") {
            made = adding("<reservationCreatorID>2200</reservationCreatorID>", to: made)
        }
        if !made.contains("<recordingFlag") { made = adding("<recordingFlag>0</recordingFlag>", to: made) }
        if !made.contains("<recordSize") {
            made = adding("<recordSize>\(estimatedSizeMB(of: made))</recordSize>", to: made)
        }
        return made
    }

    private static func ruleObject(fromElements elements: String, id newID: String) -> String {
        guard let object = element("object", in: elements) else { return "" }
        return setting(id: newID, in: object)
    }

    /// Applies a title update -- a rename, a protect, a watched flag -- to the item in the list.
    private static func patch(_ item: String, with elements: String) -> String {
        var patched = item
        for name in ["title", "titleProtectFlag", "titleNewFlag"] {
            if let value = (try? XmlNode.parse(elements))?.firstDescendantText(name) {
                patched = replacing(name, with: value, in: patched)
            }
        }
        return patched
    }

    /// What the recorder would put in `recordSize`: DR keeps the broadcast stream, the rest are re-encoded.
    private static func estimatedSizeMB(of item: String) -> Int {
        let node = try? XmlNode.parse(item)
        let seconds = Int(node?.childText("scheduledDuration") ?? "") ?? 3600
        let quality = Int(node?.childText("desiredQualityMode") ?? "") ?? 220
        return seconds / 60 * (quality == 100 ? 190 : 60)
    }

    /// The first `<name …>…</name>` of a fragment, attributes and all.
    private static func element(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)"), let close = xml.range(of: "</\(name)>") else { return nil }
        return String(xml[open.lowerBound..<close.upperBound])
    }

    /// The element with its `id` attribute set to `id`, the attribute put in where the element has none: a
    /// keyword condition is created with no id at all, and is listed with the one the create answers.
    private static func setting(id: String, in element: String) -> String {
        guard let opening = element.firstIndex(of: ">") else { return element }
        guard let quote = element.range(of: "id=\"", range: element.startIndex..<opening) else {
            return element.replacingCharacters(in: opening..<opening, with: " id=\"\(id)\"")
        }
        let rest = element[quote.upperBound...]
        let end = rest.firstIndex(of: "\"") ?? rest.endIndex
        return element.replacingCharacters(in: quote.upperBound..<end, with: id)
    }

    private static func adding(_ field: String, to element: String) -> String {
        guard let close = element.range(of: "</", options: .backwards) else { return element }
        return element.replacingCharacters(in: close.lowerBound..<close.lowerBound, with: field)
    }

    private static func replacing(_ name: String, with value: String, in element: String) -> String {
        guard let open = element.range(of: "<\(name)>"), let close = element.range(of: "</\(name)>"),
              open.upperBound <= close.lowerBound else { return element }
        return element.replacingCharacters(in: open.upperBound..<close.lowerBound, with: value)
    }

    // MARK: - the box itself

    private static let descriptionXml = """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:av="urn:schemas-sony-com:av">
          <device>
            <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
            <friendlyName>BDR - BDZ-FBT4100</friendlyName>
            <manufacturer>Sony Corporation</manufacturer>
            <modelDescription>BDZ-202105</modelDescription>
            <modelName>Sony-BDZ</modelName>
            <UDN>uuid:00000000-0000-0000-0000-000000000000</UDN>
            <av:X_ScalarWebAPI_DeviceInfo><av:EPG_CAP>03</av:EPG_CAP></av:X_ScalarWebAPI_DeviceInfo>
            <serviceList>
              <service>
                <serviceType>urn:schemas-xsrs-org:service:X_ScheduledRecording:2</serviceType>
                <controlURL>/XSRS</controlURL>
              </service>
            </serviceList>
          </device>
        </root>
        """
}
