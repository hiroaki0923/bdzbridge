import Foundation
import RecorderKit
import XCTest
@testable import RecBridgeModel

/// The rules of the guide's grid that are not drawing (`GuideGridDay.swift`, `GuideMark.swift`): which stations get
/// a column, where a programme sits in the day, where the grid opens, the scale's limits, the mark and the words a
/// block says, and the genre colours. Programmes come from the demo's guide and are then moved in time, so that
/// every number here is a literal against the day's start.
@MainActor
final class GuideGridTests: XCTestCase {
    /// The demo's guide as a model reads it, and a day built from the first programme of each of the chosen
    /// stations (by place in the station list).
    private func home() async throws -> AppModel {
        let (_, _, model) = try await connectedHome()
        XCTAssertGreaterThanOrEqual(model.channels.count, 3)
        return model
    }

    private func dayStart(of model: AppModel) -> Date {
        GuideStore.dayRange(containing: model.day).start
    }

    /// A programme of the model's guide moved to `from` minutes into the day and lasting `minutes`.
    private func program(_ model: AppModel, from: Double, lasting minutes: Double) -> GuideProgramRow {
        var row = model.programs[0]
        row.start = dayStart(of: model).addingTimeInterval(from * 60)
        row.end = row.start.addingTimeInterval(minutes * 60)
        return row
    }

    // MARK: - columns

    /// Only the stations with a programme get a column, in the order of the station list, whatever the order of
    /// the programmes; and the day starts at four.
    func testOnlyStationsWithProgrammesGetAColumnInTheStationsOrder() async throws {
        let model = try await home()
        let channels = model.channels
        var first = model.programs[0], third = model.programs[0]
        first.serviceID = channels[0].serviceID
        third.serviceID = channels[2].serviceID
        let day = GuideGridDay(channels: channels, programs: [third, first, third], day: model.day)
        XCTAssertEqual(day.columns.map(\.channel.serviceID), [channels[0].serviceID, channels[2].serviceID])
        XCTAssertEqual(day.columns.map(\.programs.count), [1, 2])
        XCTAssertEqual(day.dayStart, dayStart(of: model))
        let parts = Calendar(identifier: .gregorian).dateComponents(in: RecorderTime.timeZone, from: day.dayStart)
        XCTAssertEqual(parts.hour, 4)
        XCTAssertEqual(parts.minute, 0)
        XCTAssertTrue(GuideGridDay(channels: channels, programs: [], day: model.day).columns.isEmpty)
        XCTAssertEqual(day.key, "\(Int(day.dayStart.timeIntervalSince1970))-2")
    }

    // MARK: - a programme in the day

    func testWhereProgrammesSitInTheDay() async throws {
        let model = try await home()
        let day = GuideGridDay(channels: model.channels, programs: model.programs, day: model.day)
        XCTAssertEqual(GuideGridDay.minutes, 1440)

        let inside = program(model, from: 600, lasting: 60)
        XCTAssertEqual(day.top(of: inside), 600)
        XCTAssertEqual(day.shown(of: inside), 60)
        XCTAssertEqual(day.span(of: inside), 600...660)

        let before = program(model, from: -60, lasting: 90)
        XCTAssertEqual(day.top(of: before), 0)
        XCTAssertEqual(day.shown(of: before), 30)
        XCTAssertEqual(day.span(of: before), -60...30)

        let after = program(model, from: 1410, lasting: 90)
        XCTAssertEqual(day.top(of: after), 1410)
        XCTAssertEqual(day.shown(of: after), 30)
        XCTAssertEqual(day.span(of: after), 1410...1500)

        let none = program(model, from: 600, lasting: 0)
        XCTAssertEqual(day.top(of: none), 600)
        XCTAssertEqual(day.shown(of: none), 0)
        XCTAssertEqual(day.span(of: none), 600...600)

        // An end before the start, as the guide file can say: no span, and a negative length shown, which the
        // screen holds to a minimum height.
        let backwards = program(model, from: 600, lasting: -10)
        XCTAssertEqual(day.span(of: backwards), 600...600)
        XCTAssertEqual(day.shown(of: backwards), -10)
    }

    // MARK: - now and opening

    func testNowAndWhereTheGridOpens() async throws {
        let model = try await home()
        let day = GuideGridDay(channels: model.channels, programs: model.programs, day: model.day)
        let start = day.dayStart
        let now = start.addingTimeInterval(300 * 60)
        XCTAssertEqual(day.nowMinute(at: now), 300)
        XCTAssertEqual(day.nowMinute(at: start), 0)
        XCTAssertNil(day.nowMinute(at: start.addingTimeInterval(-1)))
        XCTAssertEqual(day.nowMinute(at: start.addingTimeInterval(1439 * 60)), 1439)
        XCTAssertNil(day.nowMinute(at: start.addingTimeInterval(1440 * 60)))
        XCTAssertNil(day.nowMinute(at: start.addingTimeInterval(86400 * 3)))

        XCTAssertEqual(day.openingMinute(pinned: "", now: now), 300, "now, when the day is today")
        XCTAssertEqual(day.openingMinute(pinned: "", now: start.addingTimeInterval(86400 * 3)), 0,
                       "the top, on another day")
        XCTAssertEqual(day.openingMinute(pinned: "19:00", now: now), 900)
        XCTAssertEqual(day.openingMinute(pinned: "02:30", now: now), 1350, "before four is the end of the day")
        XCTAssertEqual(day.openingMinute(pinned: "19:00", now: start.addingTimeInterval(86400 * 3)), 900)
        XCTAssertEqual(day.openingMinute(pinned: "soon", now: now), 300, "not a time: as if not pinned")
        XCTAssertEqual(GuideGridDay.leadIn, 15)
    }

    func testTheHourLabelsRunFromFour() {
        XCTAssertEqual((0..<24).map(GuideGridDay.hourLabel),
                       Array(4...23) + Array(0...3))
    }

    // MARK: - scale

    func testTheScaleAndItsLimits() {
        XCTAssertEqual(GuideGridScale.standard, 3)
        XCTAssertEqual(GuideGridScale.smallest, 1.5)
        XCTAssertEqual(GuideGridScale.largest, 8)
        XCTAssertEqual(GuideGridScale.step, 1.4)
        XCTAssertEqual(GuideGridScale.clamped(1.0), 1.5)
        XCTAssertEqual(GuideGridScale.clamped(1.5), 1.5)
        XCTAssertEqual(GuideGridScale.clamped(4.2), 4.2)
        XCTAssertEqual(GuideGridScale.clamped(8), 8)
        XCTAssertEqual(GuideGridScale.clamped(11.2), 8)
        XCTAssertFalse(GuideGridScale.canShrink(1.5))
        XCTAssertTrue(GuideGridScale.canShrink(1.5000001))
        XCTAssertTrue(GuideGridScale.canGrow(7.9999999))
        XCTAssertFalse(GuideGridScale.canGrow(8))
        XCTAssertTrue(GuideGridScale.canShrink(8) && GuideGridScale.canGrow(1.5))
        // Two presses from the middle, and back.
        XCTAssertEqual(GuideGridScale.clamped(3 * GuideGridScale.step * GuideGridScale.step), 3 * 1.4 * 1.4)
        XCTAssertEqual(GuideGridScale.clamped(1.6 * (1 / GuideGridScale.step)), 1.5)
    }

    // MARK: - the mark

    func testTheMarkAndWhichWins() async throws {
        let (_, _, model, row) = try await withAReservation()
        var recording = row
        recording.recording = true
        var waiting = try pending(for: try XCTUnwrap(model.programs.first))
        XCTAssertNil(GuideMark(reservation: nil, pending: nil))
        XCTAssertTrue(says(GuideMark(reservation: row, pending: nil), "予約", red: false))
        XCTAssertTrue(says(GuideMark(reservation: recording, pending: nil), "録画中", red: true))
        XCTAssertTrue(says(GuideMark(reservation: nil, pending: waiting), "送信待ち", red: false))
        waiting.problem = "refused"
        XCTAssertTrue(says(GuideMark(reservation: nil, pending: waiting), "送信待ち", red: true))
        XCTAssertTrue(says(GuideMark(reservation: row, pending: waiting), "予約", red: false),
                      "a reservation the device holds wins over one waiting")
    }

    private func says(_ mark: GuideMark?, _ word: String, red: Bool) -> Bool {
        mark?.word == word && mark?.isRed == red
    }

    // MARK: - on air, and what is said of a block

    func testOnAirEndedAndHowFarIn() async throws {
        let model = try await home()
        let row = program(model, from: 600, lasting: 60)
        let start = row.start, end = row.end
        XCTAssertFalse(row.isOnAir(at: start.addingTimeInterval(-1)))
        XCTAssertTrue(row.isOnAir(at: start))
        XCTAssertTrue(row.isOnAir(at: start.addingTimeInterval(1799)))
        XCTAssertTrue(row.isOnAir(at: end.addingTimeInterval(-1)))
        XCTAssertFalse(row.isOnAir(at: end))
        XCTAssertFalse(row.hasEnded(at: end.addingTimeInterval(-1)))
        XCTAssertTrue(row.hasEnded(at: end))
        XCTAssertEqual(row.elapsed(at: start.addingTimeInterval(-1)), 0)
        XCTAssertEqual(row.elapsed(at: start), 0)
        XCTAssertEqual(row.elapsed(at: start.addingTimeInterval(900)), 0.25)
        XCTAssertEqual(row.elapsed(at: start.addingTimeInterval(1800)), 0.5)
        XCTAssertEqual(row.elapsed(at: end.addingTimeInterval(-1)), 3599.0 / 3600.0)
        XCTAssertEqual(row.elapsed(at: end), 0)

        let none = program(model, from: 600, lasting: 0)
        XCTAssertFalse(none.isOnAir(at: none.start))
        XCTAssertTrue(none.hasEnded(at: none.start))
        XCTAssertEqual(none.elapsed(at: none.start), 0)
    }

    func testWhatVoiceOverSaysOfABlock() async throws {
        let (_, _, model, reservation) = try await withAReservation()
        var row = program(model, from: 15 * 60, lasting: 60)
        row.serviceName = "サンプルテレビ"
        row.title = "夜のドラマ"
        let start = row.start
        let mark = GuideMark(reservation: reservation, pending: nil)
        XCTAssertEqual(row.spoken(mark: nil, at: start.addingTimeInterval(-60)),
                       "サンプルテレビ、19:00から60分、夜のドラマ")
        XCTAssertEqual(row.spoken(mark: nil, at: start),
                       "サンプルテレビ、19:00から60分、夜のドラマ、放送中")
        XCTAssertEqual(row.spoken(mark: mark, at: start.addingTimeInterval(-60)),
                       "サンプルテレビ、19:00から60分、夜のドラマ、予約")
        XCTAssertEqual(row.spoken(mark: mark, at: start.addingTimeInterval(60)),
                       "サンプルテレビ、19:00から60分、夜のドラマ、放送中、予約")
    }

    // MARK: - genre colours

    func testTheTwelveGenreAccents() {
        let table: [(Int, Double, Double, Double)] = [
            (0, 0.56, 0.56, 0.58), (1, 0.20, 0.78, 0.35), (2, 1.00, 0.58, 0.00), (3, 1.00, 0.18, 0.33),
            (4, 0.69, 0.32, 0.87), (5, 1.00, 0.80, 0.00), (6, 0.00, 0.48, 1.00), (7, 0.35, 0.78, 0.98),
            (8, 0.19, 0.69, 0.78), (9, 0.64, 0.52, 0.37), (10, 0.35, 0.34, 0.84), (11, 0.00, 0.78, 0.75),
        ]
        for (level, red, green, blue) in table {
            XCTAssertEqual(GuideGenre.accent(level1: level), GuideGenre.Accent(red: red, green: green, blue: blue),
                           "genre \(level)")
        }
        XCTAssertNil(GuideGenre.accent(level1: 12))
        XCTAssertNil(GuideGenre.accent(level1: 15))
        XCTAssertNil(GuideGenre.accent(level1: -1))
        XCTAssertNil(GuideGenre.accent(level1: nil))
    }

    // MARK: - the heading

    func testTheGridSaysTheTypeWhateverTheListIsNarrowedTo() async throws {
        let model = try await home()
        XCTAssertEqual(model.guideHeading(grid: false), "地デジ")
        model.serviceFilter = model.channels[1].serviceID
        XCTAssertEqual(model.guideHeading(grid: false), model.channels[1].name)
        XCTAssertEqual(model.guideHeading(grid: true), "地デジ")
    }

    // MARK: - the buttons' names

    /// The switch says what a press does from the mode on screen, and the zoom buttons what they do to the guide.
    func testWhatTheGuidesButtonsAreCalled() {
        XCTAssertEqual(AppModel.guideModeLabel(grid: false), "表形式で表示")
        XCTAssertEqual(AppModel.guideModeLabel(grid: true), "リスト表示にする")
        XCTAssertEqual(GuideGridScale.growLabel, "表示を拡大")
        XCTAssertEqual(GuideGridScale.shrinkLabel, "表示を縮小")
    }

    private func pending(for program: GuideProgramRow) throws -> PendingReservation {
        let request = try XCTUnwrap(ReservationRequest(program: program, quality: "DR", repeating: "none"))
        return PendingReservation(request: request, serviceName: program.serviceName)
    }

    private func withAReservation() async throws
        -> (bench: Bench, recorder: NamedRecorder, model: AppModel, row: Reservation) {
        let (bench, recorder, model) = try await connectedHome()
        let programmes = try await programmesNotReserved(model, 1)
        let program = try XCTUnwrap(programmes.first)
        expectEqual(await model.reserve(program, on: .recorder, quality: "DR", repeating: "none"), .made(saying: nil))
        let row = try XCTUnwrap(model.reservations(for: program).first { $0.device == .recorder })
        return (bench, recorder, model, row)
    }
}
