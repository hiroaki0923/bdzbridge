import Foundation
import RecBridgeModel
import RecorderKit
import XCTest
@testable import AndroidBridge

/// The overnight run on Android (`NightRun`): Android's own rule that it goes only on the network of a device saved,
/// decided by the interfaces handed in; that it does nothing in the demo or off that network; that a run with the
/// demo's recorder at a saved address writes the time the settings say; and that `stop` cancels it. The recorder is
/// handed in at whatever address is saved, and no MAC is saved, so nothing reaches the LAN: the run sends its packet
/// itself, to the MAC saved.
final class NightTests: XCTestCase {
    private var folder: URL!
    private var files: String { folder.path }
    private var kept: String { folder.appendingPathComponent("kept").path }

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("night-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The Wi-Fi of the documentation's first network, where the demo's recorder and television are, and another.
    private let home = LocalNetwork.Interface(name: "wlan0", address: "192.0.2.10", netmask: "255.255.255.0",
                                              broadcasts: true)
    private let elsewhere = LocalNetwork.Interface(name: "wlan0", address: "198.51.100.10", netmask: "255.255.255.0",
                                                   broadcasts: true)

    /// A run on `files` and `kept`, on `interfaces`, reaching `recorder` and `television` at whatever address it asks,
    /// with each address it asked at noted in `reached`.
    private func night(on interfaces: [LocalNetwork.Interface], recorder: any HTTPTransport = Heard(),
                       television: any HTTPTransport = Heard(), reached: Reached = Reached()) -> NightRun {
        NightRun(files: files, kept: kept, interfaces: { interfaces },
                 transport: { host in
                     reached.note("recorder \(host)")
                     return recorder
                 },
                 tvTransport: { host in
                     reached.note("television \(host)")
                     return television
                 })
    }

    private var defaults: WrittenDefaults { WrittenDefaults.android(files: files) }

    /// The guide's cache in `files`, which a run that went on opens.
    private var cacheMade: Bool {
        FileManager.default.fileExists(atPath: Storage.guidePath(demo: false, in: folder))
    }

    /// Nothing a run writes is there: what was told once of either device, and the time of the last guide.
    private func assertNothingWritten(file: StaticString = #filePath, line: UInt = #line) {
        for key in [KeptOnce.recorderKey, KeptOnce.televisionKey, DefaultsKey.lastBackgroundRefresh] {
            XCTAssertNil(defaults.object(forKey: key), "\(key) was written", file: file, line: line)
        }
    }

    // MARK: - the rule

    /// The run goes with a recorder or a television saved at an IPv4 address on the network of an interface handed
    /// in, by that interface's mask, and not with none saved, an address saved empty, or an address on another network.
    /// An address the rule cannot place -- a name, an IPv6 address -- lets it go, on either device.
    func testARunGoesOnlyWithADeviceSavedOnTheNetworkOfAnInterface() {
        let defaults = defaults
        XCTAssertFalse(NightRun.mayGo(in: defaults, on: [home]), "with nothing saved")
        defaults.set("", forKey: DefaultsKey.recorderHost)
        XCTAssertFalse(NightRun.mayGo(in: defaults, on: [home]), "with an address saved empty")

        defaults.set("192.0.2.63", forKey: DefaultsKey.recorderHost)
        XCTAssertTrue(NightRun.mayGo(in: defaults, on: [home]))
        XCTAssertTrue(NightRun.mayGo(in: defaults, on: [elsewhere, home]), "on the second interface")
        XCTAssertFalse(NightRun.mayGo(in: defaults, on: [elsewhere]))
        XCTAssertFalse(NightRun.mayGo(in: defaults, on: []), "with no interface")

        // By the mask: within the /24 the upper half is the same network, and under a /25 another one.
        defaults.set("192.0.2.200", forKey: DefaultsKey.recorderHost)
        XCTAssertTrue(NightRun.mayGo(in: defaults, on: [home]))
        var narrow = home
        narrow.netmask = "255.255.255.128"
        XCTAssertFalse(NightRun.mayGo(in: defaults, on: [narrow]))

        // The television's alone, with the recorder's on another network or none saved.
        defaults.set("198.51.100.63", forKey: DefaultsKey.recorderHost)
        defaults.set("192.0.2.64", forKey: DefaultsKey.tvHost)
        XCTAssertTrue(NightRun.mayGo(in: defaults, on: [home]))
        defaults.removeObject(forKey: DefaultsKey.recorderHost)
        XCTAssertTrue(NightRun.mayGo(in: defaults, on: [home]))
        XCTAssertFalse(NightRun.mayGo(in: defaults, on: [elsewhere]))

        // What cannot be placed goes, on either device, beside an IPv4 address off every interface or none.
        defaults.set("recorder.local", forKey: DefaultsKey.recorderHost)
        XCTAssertTrue(NightRun.mayGo(in: defaults, on: [elsewhere]), "a name beside a television off the network")
        defaults.removeObject(forKey: DefaultsKey.tvHost)
        XCTAssertTrue(NightRun.mayGo(in: defaults, on: [home]), "a name alone")
        XCTAssertTrue(NightRun.mayGo(in: defaults, on: []), "a name with no interface")
        defaults.set("198.51.100.63", forKey: DefaultsKey.recorderHost)
        defaults.set("2001:db8::64", forKey: DefaultsKey.tvHost)
        XCTAssertTrue(NightRun.mayGo(in: defaults, on: [home]), "an IPv6 address beside a recorder off the network")
        defaults.set("television.local", forKey: DefaultsKey.tvHost)
        XCTAssertTrue(NightRun.mayGo(in: defaults, on: [home]), "a television's name beside a recorder off the network")
        defaults.set("", forKey: DefaultsKey.tvHost)
        XCTAssertFalse(NightRun.mayGo(in: defaults, on: [home]), "an empty address let it go")
    }

    // MARK: - the runs

    /// Off the network of both devices saved, the run ends before anything: no cache is opened, no way to a device
    /// made, nothing written.
    func testARunOffTheNetworkOpensAndAsksNothing() async {
        defaults.set(DemoRecorder.host, forKey: DefaultsKey.recorderHost)
        defaults.set("192.0.2.64", forKey: DefaultsKey.tvHost)
        let reached = Reached()

        let stored = await night(on: [elsewhere], reached: reached).run()

        XCTAssertFalse(stored)
        XCTAssertEqual(reached.all, [], "a way to a device was made off its network")
        XCTAssertFalse(cacheMade, "the cache was opened off the network")
        assertNothingWritten()
    }

    /// In the demo, on the network of its recorder and with a television saved there too, the run asks nothing and
    /// writes nothing: the model's entry does nothing in the demo.
    @MainActor
    func testInTheDemoTheRunDoesNothing() async throws {
        let app = RecBridgeApp.made(files: files, kept: kept, version: "0.1 (1)")
        await app.start()
        await app.devices().enterDemo()
        let defaults = defaults
        XCTAssertEqual(defaults.string(forKey: DefaultsKey.recorderHost), DemoRecorder.host)
        defaults.set("192.0.2.64", forKey: DefaultsKey.tvHost)
        XCTAssertTrue(NightRun.mayGo(in: defaults, on: [home]), "the rule, not the demo, would end the run")
        let reached = Reached()

        let stored = await night(on: [home], reached: reached).run()

        XCTAssertFalse(stored)
        XCTAssertEqual(reached.all, [], "something was asked in the demo")
        assertNothingWritten()
    }

    /// On the network of the recorder saved, the run goes through the model's: the recorder asked at its address --
    /// who it is, its slot, its free space and its guide's files -- and the time a guide was fetched written in the
    /// defaults object the screens' model has, where the settings read it and say it (最終自動更新).
    @MainActor
    func testARunOnTheNetworkWritesTheTimeWhereTheSettingsReadIt() async throws {
        defaults.set(DemoRecorder.host, forKey: DefaultsKey.recorderHost)
        let app = RecBridgeApp.made(files: files, kept: kept, version: "0.1 (1)")
        XCTAssertTrue(app.quality.defaults === defaults, "the run and the screens would have two defaults objects")
        let settings = await app.settings()
        let before = await settings.read()
        XCTAssertFalse(before.guide.contains { $0.label == "最終自動更新" }, "said before any run")
        let recorder = Heard(), reached = Reached()
        let began = Date()

        _ = await night(on: [home], recorder: recorder, reached: reached).run()

        XCTAssertEqual(reached.all, ["recorder \(DemoRecorder.host)"])
        let heard = await recorder.heard
        XCTAssertEqual(heard.first, "/description.xml")
        XCTAssertTrue(heard.contains { $0.hasSuffix("EPG_TRDEPG_FILE.dat") }, "the guide was not asked for: \(heard)")
        XCTAssertTrue(cacheMade)
        let written = try XCTUnwrap(defaults.string(forKey: DefaultsKey.lastBackgroundRefresh),
                                    "the time a guide was fetched was not written")
        let fetched = try XCTUnwrap(RecorderTime.parse(written))
        // Written to the second.
        XCTAssertTrue(fetched >= began.addingTimeInterval(-1) && fetched <= Date(), "\(written)")
        let said = try XCTUnwrap(app.model.lastOvernightRefresh)
        let after = await settings.read()
        XCTAssertEqual(after.guide.last?.label, "最終自動更新")
        XCTAssertEqual(after.guide.last?.value, said)
    }

    /// `stop` cancels the run's task, which the model's run looks at between its steps: stopped while the recorder is
    /// asked who it is, the run asks nothing after that answer and writes nothing. Stopped before it begins, it does
    /// not begin.
    func testStopCancelsTheRunsTask() async throws {
        defaults.set(DemoRecorder.host, forKey: DefaultsKey.recorderHost)
        let recorder = Heard(holding: true)
        addTeardownBlock { await recorder.letGo() }
        let overnight = night(on: [home], recorder: recorder)
        let run = Task { await overnight.run() }
        var tries = 0
        while !(await recorder.isHolding), tries < 400 {
            tries += 1
            try await Task.sleep(for: .milliseconds(25))
        }
        let holding = await recorder.isHolding
        XCTAssertTrue(holding, "the run never asked the recorder")

        overnight.stop()
        await recorder.letGo()
        let stored = await run.value

        XCTAssertFalse(stored)
        let heard = await recorder.heard
        XCTAssertEqual(heard, ["/description.xml"], "the run went on once stopped")
        assertNothingWritten()

        let reached = Reached()
        let early = night(on: [home], reached: reached)
        early.stop()
        let ran = await early.run()
        XCTAssertFalse(ran)
        XCTAssertEqual(reached.all, [], "a run stopped before it began asked something")
    }

    // MARK: - the settings

    /// The settings say when the guide was last fetched, as the model says a stored time (`Format.when(stored:)`),
    /// and under it when the overnight run last fetched one (`AppModel.lastOvernightRefresh`): nothing until a run
    /// has written its time, then that time -- here one long past, with its date.
    @MainActor
    func testTheSettingsSayWhenTheOvernightRunLastFetchedAGuide() async throws {
        let app = RecBridgeApp.made(files: files, kept: kept, version: "0.1 (1)")
        await app.start()
        await app.devices().enterDemo()
        let settings = await app.settings()
        var shown = await settings.read()
        var tries = 0
        while !shown.guide.contains(where: { $0.label == "最終更新" }), tries < 200 {
            tries += 1
            try await Task.sleep(for: .milliseconds(25))
            shown = await settings.read()
        }
        let refreshed = try XCTUnwrap(app.model.counts["td"]?.refreshed)
        XCTAssertEqual(shown.guide.last?.label, "最終更新")
        XCTAssertEqual(shown.guide.last?.value, Format.when(stored: refreshed))

        defaults.set(RecorderTime.format(Date(timeIntervalSince1970: 1_700_000_000)),
                     forKey: DefaultsKey.lastBackgroundRefresh)
        let after = await settings.read()
        XCTAssertEqual(after.guide.suffix(2).map(\.label), ["最終更新", "最終自動更新"])
        XCTAssertEqual(after.guide.last?.value, "11/15(水) 07:13")
    }
}

/// The addresses a run made a way to a device for, in order.
private final class Reached: @unchecked Sendable {
    private let lock = NSLock()
    private var reached: [String] = []

    var all: [String] { lock.withLock { reached } }

    func note(_ what: String) {
        lock.withLock { reached.append(what) }
    }
}

/// The demo's recorder at whatever address it is asked, putting down what each request asked for -- its SOAP action,
/// or its path -- and, while `holding`, keeping each request until `letGo`.
private actor Heard: HTTPTransport {
    private let recorder = DemoRecorder()
    private var holding: Bool
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var heard: [String] = []

    init(holding: Bool = false) {
        self.holding = holding
    }

    var isHolding: Bool { !held.isEmpty }

    func letGo() {
        holding = false
        for request in held { request.resume() }
        held = []
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        heard.append(request.headers["SOAPACTION"] ?? request.url.path)
        if holding { await withCheckedContinuation { held.append($0) } }
        return try await recorder.send(request)
    }
}
