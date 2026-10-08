import Foundation
import Network
import RecorderKit
import SwiftUI
import UserNotifications

/// Everything the screens share: which recorder we talk to, the guide cache, and what is on screen now.
///
/// There is no server in the middle. The app holds one `RecorderClient` at a time, in its link to the
/// recorder, which serialises its own requests, and one `GuideStore` on disk, so the guide can be read while
/// away from home.
///
/// This file holds the state, how the model is made and started, and the one funnel every action runs
/// through. What it does is in extensions beside it, one file to a concern: `AppModelSession` (the app's side
/// of the connection: what the link tells it, what the link reaches, coming and going from the foreground),
/// `AppModelSetup` (the demo, the address, the scan), `AppModelGuide`, `AppModelReservations` (with the
/// queue), `AppModelRecorderRules`, `AppModelRecordings` and `AppModelBulkWork` (with the duplicates).
///
/// An extension in another file cannot reach what is private, so much of the state below is internal and
/// settable. That is for the extensions, not for the screens: nothing outside the `AppModel` files should
/// set it. The exception is `session`, which no file here can set a field of.
@MainActor
@Observable
final class AppModel: LinkHost {
    /// The connection to the recorder: its address, its client, what is known of it and when it is asked again
    /// (`DeviceLink`, with the recorder's ways in `RecorderDriver`). It tells the model what the screens need to
    /// hear (`LinkHost`, in `AppModelSession`).
    let recorder: DeviceLink
    /// The television's link, while one is saved -- in the demo, while the demo's is added -- (`makeTVLink`), and
    /// what it tells the app: kept by a host of its own, the television's reservations with it, so that what a
    /// television said goes when its link does.
    var tv: DeviceLink?
    var tvHost: TVHost?
    /// Bumped each time the television's link is let go of (`dropTVLink`), for the screens to let go of what
    /// they hold of that television, as `timesForgotten` has them do for a recorder.
    var tvTimesForgotten = 0
    /// The television's lines among `activities`: what the television does is no reason to hold the recorder's
    /// rules or buttons back (`isBusy`), nor the recorder's the television's.
    var televisionLines: Set<Activities.Token> = []
    /// The client id a registration under way goes with, until the PIN it asked for comes back with it.
    var tvClientID: String?
    /// Set while an address given for a television said nothing because the system keeps the app off the local
    /// network: the sheet that adds it says so, with the way to the Settings app, and goes on by itself once the
    /// permission comes (`findTV`).
    var tvAddressTurnedAway = false
    /// Counts what is asked at an address given for a television (`findTV`), so that one the sheet's closing
    /// ended (`stopFindingTV`) does not go on when the permission comes after it.
    var tvFindRun = 0

    /// The recorder's address on the LAN: one a scan found or one typed in (`adopt`), or wherever the router
    /// has moved it since (`RecorderDriver.findElsewhere`). Written down whenever it is set (`keepAddress`).
    var host: String {
        get { recorder.host }
        set { recorder.host = newValue }
    }

    /// Whether the app opens on the tutorial: nothing is set up yet, neither a recorder nor a television. A home
    /// with a television and no recorder has set up what it has, and is not to meet the tutorial at every launch.
    /// The television's link is made with the model (`makeTVLink`), so this is right before `start()`.
    var welcomes: Bool { host.isEmpty && tv == nil }

    /// Changing it lets go of the channel the list was narrowed to: a channel belongs to one broadcasting
    /// type, and one chosen on another would leave the list empty.
    ///
    /// Kept across launches, as the two orders below are. The filters are not: a list opened narrowed to a
    /// genre, a watch state or one kind of reservation, with only a filled-in icon to say so, reads as
    /// recordings or reservations gone missing. A launch argument for any of the three keys pins it, which
    /// is how the UI tests start from the same screen.
    var broadcasting = "td" {
        didSet {
            if broadcasting != oldValue { serviceFilter = nil }
            defaults.set(broadcasting, forKey: DefaultsKey.guideBroadcasting)
        }
    }
    var day: Date
    var reservationSort = ReservationSort.time {
        didSet { defaults.set(reservationSort.rawValue, forKey: DefaultsKey.reservationSort) }
    }
    var reservationKind = ReservationKind.all
    var titleGenre: Int?
    var titleState: WatchState?
    var titleSort = TitleSort.newest {
        didSet { defaults.set(titleSort.rawValue, forKey: DefaultsKey.recordingsSort) }
    }
    var serviceFilter: Int?

    /// What is known of the recorder and of the link to it: whether it is described, unreachable, given up
    /// on, being woken, and the rest. It changes only by what happened to it (`SessionState`), and the screens
    /// read it through the properties below, which cannot be set.
    ///
    /// What happened is the model's to say, not a screen's, since some of it has more to it than the session
    /// keeps: `forgetMac()` here also takes the MAC out of the defaults the overnight run reads.
    var session: SessionState { recorder.session }

    var info: RecorderDescription? { session.info }
    /// Empty, and `storage` nil, when the recorder would not say. Both are only shown, and another model of
    /// the series need not give them: see `RecorderDriver.attach`.
    var firmware: String { session.firmware }
    var storage: (free: Int, total: Int)? { session.storage }
    /// The disk in the recorder's USB slot as last known, a registered one; nil in a home with no USB disk, which
    /// is then shown nothing of one (`RecorderDriver.usbDisk`). Shown as it was read while the slot, right after a
    /// waking, answers none and is to be read again (`SessionState.usbDisk`).
    var usbDisk: RecorderDisk? { session.usbDisk }
    /// What a new reservation or condition can be made to, for the pickers (`RecorderDisk.choices`): nothing in a
    /// home with no USB disk, which is then drawn no picker. A disk kept through an answer of none is offered as
    /// one answered is, as the settings show it: the recorder answers it seconds after a wake, and a picker that
    /// waited for the read again would turn up under the reader half a minute later.
    var diskChoices: [RecorderDisk] { RecorderDisk.choices(with: usbDisk) }

    /// What a reservation can be moved between on its sheet, the internal disk always among them once it is off
    /// it; nothing for a television's, nor in a home with no USB disk (`RecorderDisk.choices(keeping:on:with:)`).
    func diskChoices(for reservation: Reservation) -> [RecorderDisk] {
        RecorderDisk.choices(keeping: reservation.destination, on: reservation.device, with: usbDisk)
    }

    /// One of the recorder's disks as the screens name it: the internal disk as the recorder writes it, the slot
    /// by the name of the disk known there, or by its id once none is. For a disk picked, which a row's rule
    /// (`diskShown`) would leave unnamed when it is the internal one.
    func diskLabel(_ destination: String) -> String {
        RecorderDisk.label(destination, named: usbDisk?.destination == destination ? usbDisk?.name : nil)
    }

    /// The disk a picker shows for what the reader picked: that while it is offered, otherwise the internal
    /// disk. What is sent is what was picked, not this, so that a disk gone meanwhile is refused (`reserve`).
    func diskOffered(_ picked: String?) -> String {
        picked.flatMap { id in diskChoices.contains { $0.destination == id } ? id : nil } ?? RecorderDisk.internalID
    }

    /// Whether a disk the reader picked could not be had when it was last sent: no longer offered, or the slot
    /// answered no disk while it was waited for (`RecorderDriver.withholds`). A sheet goes back to the internal
    /// disk then.
    func diskCannotBeHad(_ picked: String) -> Bool {
        !RecorderDisk.offers(picked, with: usbDisk) || diskNotHad == picked
    }

    /// The slot, when the last request that could name a disk of the recorder's -- a reservation, a change, a
    /// condition, a clash check -- was not sent because the slot answered no disk it could record to while it was
    /// waited for; nil when that request went, or failed for anything else. The driver decides it, and the session
    /// holds it (`SessionState.diskNotHad`).
    var diskNotHad: String? { session.diskNotHad }

    /// Set while the USB slot is waited for before something that names it is sent, which a sheet says as it says
    /// a waking (`WakingSection`).
    var settlingTheSlot: Bool { session.settlingTheSlot }

    var recorderDriver: RecorderDriver? { recorder.driver as? RecorderDriver }

    var counts: [String: GuideCounts] = [:]
    var channels: [Channel] = []
    /// Every channel's name and logo, of every broadcasting type, so a reservation or a search result can
    /// say where it comes from.
    var channelNames: [String: String] = [:]
    var channelLogos: [String: Data] = [:]
    var programs: [GuideProgramRow] = []
    /// How many reads of the guide from the cache are under way (`reloadFromCache`). While one is, what the
    /// guide lists is about to be replaced: see `GuideScreen.scroll`.
    var guideReads = 0
    var reservations: [Reservation] = [] {
        // Here, whoever sets the list. Only the load built the index, so a reservation just cancelled --
        // taken out of the list by hand, and again after a reload that can be a moment behind the recorder
        // -- went on being marked 予約 in the guide.
        didSet { reservationsByProgram = Self.byProgram(reservations) }
    }
    var titles: [RecordedTitle] = []
    /// Recordings are read in pages of 200 and there are well over a thousand, so they are kept once fetched.
    var titlesLoaded = false
    /// Reservations by the programme they follow, so the guide can mark what is already set to record.
    private(set) var reservationsByProgram: [String: Reservation] = [:]
    /// The recorders the last scan found, in the order they answered.
    var found: [RecorderDescription] = []
    /// The televisions the last scan found, in the order they answered. A choice of recorder leaves them
    /// (`adopt`); a press and a change of recorder in play clear them, as they clear `found`.
    var foundTelevisions: [TVSighting] = []
    var scanning: (done: Int, total: Int)?
    /// What the last scan came to, said right under the button that started it. Kept apart from `problem`,
    /// which every screen shows as a failure.
    var scanOutcome: ScanOutcome?
    /// Set while a scan is taken to be held up by local network privacy -- the system's question is on screen,
    /// or was answered no -- its look through the subnet having been turned away (`scanForDevices`), so that
    /// the screens can say so and offer the Settings app.
    var scanBlocked = false
    /// Whether レコーダーとテレビを探す is held back, with its small spinner, on every screen that has it: while a
    /// scan is under way and the notice about the permission is not up. Behind the notice the button is the
    /// reader's, and a press starts over (`scanForDevices` ends the scan under way). It is a new local
    /// network operation in the foreground, which is what puts the system's question up while the permission
    /// is undecided -- of one turned away in the background, "If, later on, the app performs a local network
    /// operation while in the foreground, the system presents the alert to the user as if this were the first
    /// local network operation" (TN3179). Whether a question left unanswered comes back so has not been seen.
    var scanHoldsTheButton: Bool { scanning != nil && !scanBlocked }
    /// Set when the recorder said nothing because local network privacy stopped the app asking. The app
    /// is then waiting for the permission rather than for the recorder; see `waitForPermission(at:)`.
    var connectBlocked: Bool { session.connectBlocked }
    /// Either of the two: something the reader wants is waiting on the local network permission.
    var lanBlocked: Bool { scanBlocked || connectBlocked }
    /// The scan under way, kept so that leaving the tutorial or turning to the demo can stop it -- above all
    /// while it asks again behind the system's question, which could otherwise outlive the screen that asked.
    var scanTask: Task<Void, Never>?
    /// Counts scans, so that what an earlier one reports late is not taken for the one running now.
    var scanRun = 0
    /// Waits for the local network permission after the link ran into it, and tells the link when it comes
    /// (`DeviceLink.permissionArrived`).
    var accessWatch: Task<Void, Never>?
    /// Everything under way with the recorder, each with a line of its own, since work overlaps (`Activities`).
    var activities = Activities()
    /// What the app is doing with the recorder, for the strip and the screens to say. Nil when nothing is.
    var busy: String? { activities.current }
    /// Set while the app is only waiting for the recorder to come back from a magic packet, or looking for it
    /// at another address after that (`RecorderDriver.findElsewhere`). Nothing is being written or read, so
    /// the screens leave alive what they can: a reservation made meanwhile goes to the queue.
    var waking: Bool { session.waking }
    /// Set once the recorder has been given every chance and did not answer. Nothing is asked of it again
    /// until the network this device is on changes or the reader asks: the answer would be the same, and
    /// each ask costs a timeout, one after another in a client that serialises its requests.
    var gaveUp: Bool { session.gaveUp }
    /// Set when the recorder answered that it is in network standby, so the caller can offer to wake it.
    var needsPower: Bool { session.needsPower }
    /// Set when the recorder answered nothing at all rather than answering with an error.
    var unreachable: Bool { session.unreachable }
    var problem: String?
    /// Set when a reservation went to the queue instead of the recorder, so a screen can say so once.
    var queued: PendingReservation?
    /// The MAC a magic packet is sent to. The recorder reports it whenever it is reached; the reader can
    /// also type it, for a recorder that has never been reached from this phone.
    var mac: String? { session.mac }
    /// Where notification permission stands, for the settings to say. Nil until it has been read. The app
    /// changes it itself -- provisionally after the first connect, with the dialog when a reservation is
    /// queued -- and the reader can change it in the Settings app, so it is read again after each.
    var notifications: UNAuthorizationStatus?

    var store: GuideStore?
    /// The recorder's client: the attempt's under way, or the last one's. Nil when the recorder has been let go of.
    var client: RecorderClient? { recorder.client as? RecorderClient }
    /// Opening the cache and reading it, shared by every caller of `start()` and by `connect()`.
    private var opening: Task<Void, Never>?
    /// Set once the first connect has been set going, so that it is set going once, however many screens
    /// call `start()`.
    private var launched = false
    var pathMonitor: NWPathMonitor?
    /// Kept for as long as the demo lasts, because it holds what the reader has done to it: a reservation
    /// made in the demo has to still be there after a reconnect.
    var demoRecorder: DemoRecorder?
    /// The demo's television, made the first time the demo reaches its address (`theDemoTV`) and kept for as
    /// long as the demo lasts, as the recorder is; what the demo registered with it, and the address it was
    /// added at, which is the demo's in place of the one saved (`makeTVLink`). In memory only, and never in the
    /// defaults or the Keychain: the real television's are as they were when the demo ends, and a launch with
    /// the demo on has no television.
    var demoTV: DemoTV?
    var demoTVCredentials: MemoryTVCredentials?
    var demoTVHost: String?
    /// Two connects at once would mean two clients, two magic packets and two conversations with a recorder
    /// that answers 503 to the second. The network monitor can fire at any moment, so this is not academic.
    var connecting: Bool { session.connecting }
    /// Set when the app went to the background, and cleared when it is back in front. See `wentToBackground`.
    var inBackground = false
    /// Whether the app is the one in front and taking touches (`ScenePhase.active`), as the first screen tells
    /// it at each change (`activeChanged`). Not the same as being out of the background: Control Centre and the
    /// app switcher take the app out of it without its going anywhere. Whether the system's question about the
    /// local network does has not been seen; the log's phase lines will say. Nothing goes by it: it is for the
    /// log of a scan for a recorder.
    var appIsActive = true
    /// A bulk job waiting between two steps for the app to come back. See `readyForNextStep`.
    var backInFront: CheckedContinuation<Void, Never>?
    /// The background task the step of a bulk job under way runs under. See `keepingAlive`.
    var stepTask = UIBackgroundTaskIdentifier.invalid
    /// Where the settings and the database are kept, how requests reach the recorder, and what the model
    /// does on the network by itself. The app's own everywhere but in the unit tests; see `Surroundings`.
    let surroundings: Surroundings
    var defaults: UserDefaults { surroundings.defaults }

    init(surroundings: Surroundings = .app) {
        self.surroundings = surroundings
        let defaults = surroundings.defaults
        let demo = DemoData.on(in: defaults)
        self.demo = demo
        let days = GuideStore.broadcastDays()
        self.days = days
        // The address as saved, or the demo's, and nothing written while the model is made: the unit-test host
        // and a launch in the background make one too. The demo's is set here rather than in `start()`: the first
        // screen decides whether to show the tutorial by looking at whether a recorder is set, before `start()`.
        let saved = defaults.string(forKey: DefaultsKey.recorderHost) ?? ""
        recorder = DeviceLink(
            host: demo ? DemoData.host : saved,
            session: SessionState(mac: demo ? DemoData.mac : defaults.string(forKey: DefaultsKey.recorderMac)),
            driver: RecorderDriver(busyRetryDelay: surroundings.busyRetryDelay),
            environment: Self.nowhere)
        // Anything else saved under these -- a type the app no longer offers, an order it has dropped -- is
        // left for the defaults above.
        if let saved = defaults.string(forKey: DefaultsKey.guideBroadcasting),
           GuideRefresh.broadcastingTypes.contains(saved) {
            broadcasting = saved
        }
        if let saved = defaults.string(forKey: DefaultsKey.reservationSort).flatMap(ReservationSort.init(rawValue:)) {
            reservationSort = saved
        }
        if let saved = defaults.string(forKey: DefaultsKey.recordingsSort).flatMap(TitleSort.init(rawValue:)) {
            titleSort = saved
        }
        day = days.first ?? Date()
        recorder.environment = linkEnvironment()
        recorder.owner = self
        makeTVLink()
    }

    var connected: Bool { session.connected }

    /// Bumped each time a connect reaches the recorder (`RecorderDriver.attach`), which is before it goes on to
    /// read the reservations and the guide. A count rather than a flag: see `WelcomeView`.
    var timesAttached: Int { session.timesAttached }

    /// True while the app is showing the invented recorder rather than a real one. Every screen says so, and
    /// the demo writes its guide to a database of its own, so nothing of it is left behind afterwards. A copy
    /// of `DemoData.on` rather than a read of it: that lives in UserDefaults, where no screen sees it change.
    var demo: Bool

    /// True while something is going on that a second request would only get in the way of. Waking is not
    /// one of them, on purpose -- see `waking`.
    var working: Bool { isBusy && !waking }

    /// Whether the recorder in play may be changed now: into the demo or out of it, or to another address.
    /// Not while anything is under way with the one in play: a connect or a load carries on with the client
    /// it started with, and what it reads lands on the screens of whichever recorder came after it. `busy`
    /// alone leaves gaps inside a connect, such as the check of the local network permission, so `connecting`
    /// counts as well. Nor while a bulk job runs, which holds the client and the list it started from. Nor
    /// while the recorder is being made sure of (`wakeIfDozing`), whose first ask has no line of its own: a
    /// recorder it wakes would be attached as whichever recorder is in play by then. The television's work
    /// does not count: it is on a client of its own.
    var canChangeRecorder: Bool { !isBusy && !connecting && !jobRunning && wakeCheck == nil }

    /// True while there is no point asking the recorder anything: either nothing has been set up, or the
    /// last ask got silence. Every list guards on it, so that going out of range costs one timeout rather
    /// than one per screen.
    var offline: Bool { client == nil || unreachable }

    /// Whether this device is on a different network from the one the last attempt was made on.
    var networkChanged: Bool { recorder.networkChanged }

    /// Bumped when the reader asks to be taken back to what is on now. A count rather than a flag, so that
    /// asking twice works.
    var nowRequests = 0

    /// Bumped each time what a recorder said is let go of (`forgetWhatTheRecorderSaid`), for the screens to
    /// let go of what they hold of it: a row picked for a dialog, and the sheets on a recording or a
    /// reservation, which close themselves (`closesWithItsRecorder`, `closesWithItsDevice`). Left up over an
    /// emptied list, a sheet's buttons would send its row's number to the next recorder.
    var timesForgotten = 0

    /// Opens the cache and shows what is in it. Every screen awaits this before asking for anything, and
    /// only the first caller does the work.
    ///
    /// The first call also sets the first connect going, without waiting for it. Waiting was a deadlock when
    /// something the connect did awaited this in turn, so nothing `connect()` reaches may await this; it uses
    /// the `...Now` loads, which do not. Not waiting also lets a search, which needs nothing but the cache,
    /// answer at once rather than after half a minute of waking a recorder that is not there.
    func start() async {
        // The days were worked out when the model was made, and a process the system started in the night
        // for the overnight run is still here when the app is opened in the morning.
        let moved = followTheClock()
        await openCache()
        if moved { await reloadFromCache() }
        guard !launched, store != nil else { return }
        launched = true
        Task { await self.connectFirstTime() }
    }

    /// Shows the cached guide before touching the network, so something is on screen at once. Safe to
    /// await from anywhere, `connect()` included, because nothing in it goes near the recorder.
    func openCache() async {
        if opening == nil { opening = Task { await self.readCache() } }
        await opening?.value
    }

    private func readCache() async {
        guard store == nil else { return }
        do {
            store = try GuideStore(path: try guidePath(),
                                   busyTimeoutMilliseconds: surroundings.storeBusyTimeoutMilliseconds)
            // Invented programmes: for the screenshots, and for anyone without a recorder to hand. See
            // DemoData.
            if demo, let store { try? await DemoData.seed(store: store) }
            await reloadFromCache()
            // A guide cached by a build that searched only titles and descriptions is made searchable by its
            // details here, once, in place: fetching it again would need the recorder. The guide is on
            // screen by now, and a search made meanwhile waits for this rather than missing the cast.
            if let store { Task { _ = try? await store.updateSearchText() } }
        } catch {
            problem = "番組表の保存領域を開けませんでした: \(error)"
        }
    }

    /// The database of whichever recorder is in play, the demo's or a real one's.
    func guidePath() throws -> String {
        Storage.guidePath(demo: demo, in: try surroundings.folder())
    }

    private func connectFirstTime() async {
        // Beside the recorder's rather than after it: neither device's silence holds the other up.
        let television = Task { await self.tv?.connect() }
        if !host.isEmpty { await connect() }
        await television.value
        // After the first attempt, not before it: `NWPathMonitor` reports the path it already has as
        // soon as it starts, and that would be a second connect racing the first.
        watchNetwork()
    }

    /// The check under way, so that everything asked for while it runs waits for its answer rather than
    /// sending a probe -- and a magic packet -- of its own.
    var wakeCheck: Task<NotUp?, Never>? { recorder.wakeCheck }

    /// How many guide downloads are under way. A count, so that one ending does not say the other has.
    var guideDownloads = 0

    // MARK: - the recorder's own keyword conditions (おまかせ・まる録)

    var recorderRules: [RecorderRule] = []
    /// Whether `recorderRules` is the recorder's answer, and why the last read failed if it did. An empty list
    /// is also what there is while the first read is on its way and after one that failed, and saying
    /// 条件が登録されていません then tells the reader something the recorder never said.
    var recorderRulesLoaded = false
    var recorderRulesFailure: String?

    /// Reservations made while the recorder could not be reached, waiting for it to answer.
    var pending: [PendingReservation] = [] {
        didSet { pendingByProgram = Self.byProgram(pending) }
    }

    /// The same by the programme each is for, so that the guide, the search results and the programme's
    /// sheet can say it is waiting.
    var pendingByProgram: [String: PendingReservation] = [:]

    /// The ids of the television's waiting rows a delete is under way for, so that a row has one delete at a
    /// time (`deleteWaiting`).
    var deletingWaiting: Set<String> = []

    /// What the last sending of the queue came to, and how many reservations are held for another recorder,
    /// for the strip to say until the reader closes it or leaves the app. See `tellTheStrip`.
    var flushReport: String?

    /// Set when another recorder has answered where the last one had been and nobody chose it: at a connect
    /// made over the last one's lists (`anotherDeviceDescribedItself`), or at the check before an operation
    /// (`anotherAnsweredTheCheck`). The strip says so until the reader closes it or leaves the app: the failure line
    /// lasts only until the connect that follows, and an alert goes with its sheet when that closes with
    /// the lists.
    var anotherTookOver = false

    /// The lists the reader had read when another recorder answered a connect made while the app was
    /// connected, for that connect to read again from the one that answered. See `anotherDeviceDescribedItself`.
    var listsToReadAgain = (recordings: false, rules: false)

    var job: BulkJob?
    var duplicates: [DuplicateSet] = []
    /// Which copies are ticked for deletion; the ones left unticked are kept. It lives here because the view
    /// holding it is thrown away every time the reader looks at the list or the programmes instead.
    var duplicatePicks: Set<String> = []
    /// How many candidates were left out of the sets because their text has not been read, which a scan run
    /// again reads.
    var unreadDuplicates = 0
    /// What the recorder said each recording is about, cached on disk as well. Only what it actually said:
    /// a recording missing here has not been read.
    var summaries: [String: String] = [:]
    /// The candidates' titles whose text the guide shows on more than one day: a text the programme carries
    /// every time, which does not make two recordings the same broadcast. Read from the guide at each scan.
    var fixedBlurbs: Set<Duplicates.Blurb> = []
    var jobTask: Task<Void, Never>?

    /// The eight days the recorder's guide covers, starting with the broadcast day on air, which until four
    /// in the morning is yesterday's. Kept rather than worked out each time they are read, and replaced by
    /// `followTheClock` only when that first day changes, so that the day strip keeps its chips and its place.
    var days: [Date]

    /// Runs one action, keeping whatever went wrong on screen. The message is cleared only by something
    /// that works: clearing it on the way in meant a failure could be wiped by the very next request.
    ///
    /// A recorder that has been quiet a while is made sure of first, under the action's own line, so the
    /// screen says what the reader asked for from the moment they asked. Silence on the way leaves the app
    /// offline. `sending` marks an action that changes something on the recorder, which silence leaves
    /// unknown rather than undone, and the reader is told so.
    ///
    /// The check, the clearing and what each failure says and leaves behind are the link's
    /// (`DeviceLink.run`), which a television's operations go through as well. What is the recorder's is
    /// handed to it: the sentence for a write that met silence.
    @discardableResult
    func run(_ what: String, sending: Bool = false, _ work: () async throws -> Void) async -> Bool {
        await run(what, sending: sending) { (_: Activities.Token) in try await work() }
    }

    /// The same, handing the work its own line so that it can say how far it has got.
    @discardableResult
    func run(_ what: String, sending: Bool = false,
                     _ work: (Activities.Token) async throws -> Void) async -> Bool {
        // The line is put up here rather than by the link, whose token is nil where it has no host: the work
        // always has a line to say how far it has got on. Nor is the link's client taken: each action asks
        // the one its caller had in hand, which is the one the check is asked with.
        let activity = activities.begin(what)
        defer { activities.end(activity) }
        let ran = await recorder.run(sending: sending ? Self.mayHaveArrived : nil) { _ in
            try await work(activity)
        }
        if case .success = ran { return true }
        return false
    }
}
