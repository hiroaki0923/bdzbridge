import RecorderKit
import SwiftUI

@main
struct BDBridgeApp: App {
    @State private var model = AppModel()

    init() {
        guard !Self.hostingUnitTests else { return }
        BackgroundWork.register()
        BackgroundWork.schedule()
    }

    var body: some Scene {
        WindowGroup {
            if Self.hostingUnitTests {
                // Nothing on screen, so nothing that starts the model: see `hostingUnitTests`.
                Color.clear
            } else {
                RootView()
                    .environment(model)
            }
        }
    }

    /// True when the app has been launched only to host `BDBridgeTests`, which run inside it. Its own start is
    /// left out then -- the screens, which start the model, and the overnight task -- or it would connect to
    /// whatever recorder this simulator last saved, beside the models the tests make. XCTest sets this variable
    /// in the process it runs unit tests in; the UI tests launch the app as a process of its own, without it.
    static let hostingUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    /// `-startTab reservations` on the command line opens that tab, which is how the screens are checked in a
    /// simulator without tapping through them.
    @State private var tab = UserDefaults.standard.string(forKey: DefaultsKey.startTab) ?? "guide"
    /// Up until a recorder has been chosen, the tutorial is the first thing on screen.
    @State private var welcoming = false

    /// Tapping a tab that is already showing is a "take me home" gesture, and the guide's home is now.
    /// A plain binding cannot tell that apart from a change, so this one compares before it assigns.
    private var selection: Binding<String> {
        Binding(get: { tab }, set: { chosen in
            if chosen == tab, chosen == "guide" { model.goToNow() }
            tab = chosen
        })
    }

    var body: some View {
        TabView(selection: selection) {
            GuideScreen()
                .tabItem { Label("番組表", systemImage: "squareshape.split.3x3") }
                .tag("guide")
            SearchScreen()
                .tabItem { Label("検索", systemImage: "magnifyingglass") }
                .tag("search")
            ReservationsScreen()
                .tabItem { Label("予約", systemImage: "clock") }
                .tag("reservations")
            RecordingsScreen()
                .tabItem { Label("録画", systemImage: "play.rectangle") }
                .tag("recordings")
            SettingsScreen()
                .tabItem { Label("設定", systemImage: "slider.horizontal.3") }
                .tag("settings")
        }
        .task {
            welcoming = model.host.isEmpty
            await model.start()
        }
        // From the first phase too, not only from changes: a window the system makes again for a process that
        // stayed alive in the background can come up already active, and a bulk job waiting for the app to come
        // back would then wait for good. An ordinary launch has not been away: `start()` connects then.
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .background: model.wentToBackground()
            case .active: Task { await model.returnedToForeground() }
            default: break
            }
        }
        .fullScreenCover(isPresented: $welcoming) { WelcomeView() }
    }
}

/// The grey circle a sheet is closed with. A word there would be one the system never uses; the word stays
/// for anything reading the screen aloud. The identifier is for the screenshot tests, which check that no
/// sheet is open and cannot go by the word: the system's own button beside an open search field says it too.
struct SheetCloseButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("閉じる")
        .accessibilityIdentifier("sheet-close")
    }
}

extension AppModel {
    /// What the strip at the top of a screen says: one thing at a time. Which one is chosen here and not in
    /// the view that draws it, so that the order can be held by a test.
    enum Strip: Equatable {
        /// Something is under way with a device, and this is its line.
        case busy(String)
        /// Another recorder answered where the last one had been (`anotherTookOver`).
        case anotherTookOver
        /// What became of what was waiting (`queueReport`). `inFull`: not cut at three lines. With a
        /// television saved, what a sending to one says can end with what making a reservation did to
        /// another, which is the last thing a cut would leave.
        case report(String, inFull: Bool)
        /// Everything on screen is invented.
        case demo
        /// The local network permission stands between the app and the recorder.
        case blocked
        /// The recorder was given every chance and did not answer.
        case recorderGaveUp
        /// The television answers, and takes nothing until the app is registered with it again.
        case tvNeedsPairing
        /// The television was given up on.
        case tvGaveUp
    }

    /// The first of these that holds, or nil when the strip has nothing to say. `inSheet` for the strip at
    /// the top of a sheet, which leaves the demo's line to the screen underneath
    /// (`RecorderActivityBar.inSheet`).
    ///
    /// That another recorder took over is said only while connected: the line says the lists were read
    /// again, which they were not if that recorder went quiet before it had been asked, and then the strip
    /// offers the reconnect instead and says this after it. It is ahead of the queue's line, which says
    /// what became of the reservations waiting under the same change of recorder and is read better
    /// knowing of it. The queue's line is ahead of the reconnect in turn: a sending the recorder walked
    /// out of says which were sent, and the strip goes back to offering the reconnect once that is closed.
    /// The television's own lines come after everything about the recorder, and only when one is saved.
    func strip(inSheet: Bool = false) -> Strip? {
        if let busy { return .busy(busy) }
        if anotherTookOver, connected { return .anotherTookOver }
        if let line = queueReport { return .report(line, inFull: tv != nil) }
        if demo, DemoData.banner, !inSheet { return .demo }
        if connectBlocked { return .blocked }
        if gaveUp { return .recorderGaveUp }
        if tvDriver?.facts.needsPairing == true { return .tvNeedsPairing }
        if tv?.session.gaveUp == true { return .tvGaveUp }
        return nil
    }
}

/// What the app is doing with the recorder, on whatever screen the reader is looking at. Waking takes the
/// better part of ten seconds and the screens otherwise sit there looking broken, so it says so; it appears
/// only while something is under way and slides out when it is done. Which line it shows is the model's to
/// choose (`AppModel.strip`); this draws the one chosen.
struct RecorderActivityBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set for the strip at the top of a sheet. The demo's strip is left to the screen underneath: its 終了
    /// would end the demo under a sheet still showing one of the demo's recordings, whose buttons would then
    /// go to whichever recorder came after it.
    var inSheet = false
    @State private var registeringTV = false

    /// Whether any strip is up: what the animation follows. Not which strip it is, nor what it says: one strip
    /// taking over from another -- レコーダーを起動しています giving way to レコーダーに接続していません -- is
    /// swapped in place, where two sliding past each other would show both for a moment.
    private var showing: Bool { model.strip(inSheet: inSheet) != nil }

    var body: some View {
        // A container that stays when the strip goes, so that the strip's own transition has somewhere to run.
        VStack(spacing: 0) { content }
            .animation(.default, value: showing)
            .sheet(isPresented: $registeringTV) { TVRegisterSheet(host: model.tv?.host ?? "") }
    }

    @ViewBuilder
    private var content: some View {
        if let chosen = model.strip(inSheet: inSheet) {
            switch chosen {
            case .busy(let busy):
                strip {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.footnote)
                    Spacer()
                }
            case .anotherTookOver:
                report(AppModel.anotherTookOverLine, icon: "arrow.left.arrow.right") {
                    model.anotherTookOver = false
                }
            case .report(let line, let inFull):
                // For the recorder and then for the television, whichever screen the app came back to.
                report(line, icon: "clock.arrow.trianglehead.counterclockwise.rotate.90", inFull: inFull) {
                    model.closeQueueReport()
                }
            case .demo:
                // Said on every screen, because everything on them is invented and a reader who forgets
                // that would take the free space, the recordings and the reservations for their own.
                strip {
                    Image(systemName: "theatermasks").font(.footnote)
                    Text("サンプルデータを表示しています").font(.footnote)
                    Spacer()
                    // Not while a connect or a job is under way, which `busy` alone does not always show:
                    // see `canChangeRecorder`.
                    Button { Task { await model.leaveDemo() } } label: {
                        Text("終了").hitArea(horizontal: 13, vertical: Self.rim)
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(!model.canChangeRecorder)
                }
            case .blocked:
                // Not given up: the app connects the moment the permission comes. Giving it is the one
                // thing the app cannot do, so the strip offers the way to the switch instead of 再接続,
                // which would only run into the same refusal.
                strip {
                    Image(systemName: "lock.shield").font(.footnote)
                    Text("ローカルネットワークが許可されていません").font(.footnote)
                    Spacer()
                    OpenSettingsButton()
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
            case .recorderGaveUp:
                // The app has stopped trying, and says so rather than leave it to be guessed from lists
                // that never fill. Trying again is the reader's to ask for: on this network the answer
                // will be the same, at the cost of half a minute of waking. It asks by itself only when
                // the network changes.
                strip {
                    Image(systemName: "wifi.exclamationmark").font(.footnote)
                    Text("レコーダーに接続していません").font(.footnote)
                    Spacer()
                    // Not while a bulk job runs, when connecting does nothing: see `connect()`.
                    Button { Task { await model.connect() } } label: {
                        Text("再接続").hitArea(horizontal: 13, vertical: Self.rim)
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(model.jobRunning)
                }
            case .tvNeedsPairing:
                // It answers, so it is there; nothing can be asked of it until the app is registered with
                // it again.
                strip {
                    Image(systemName: "tv").font(.footnote)
                    Text("テレビの登録が必要です").font(.footnote)
                    Spacer()
                    Button { registeringTV = true } label: {
                        Text("登録").hitArea(horizontal: 13, vertical: Self.rim)
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            case .tvGaveUp:
                strip {
                    Image(systemName: "tv").font(.footnote)
                    Text("テレビに接続していません").font(.footnote)
                    Spacer()
                    Button { Task { await model.tv?.connect() } } label: {
                        Text("再接続").hitArea(horizontal: 13, vertical: Self.rim)
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
        }
    }

    /// The strip's padding above and below what it says, and so as far as a button's tap area may reach up and
    /// down. Any further and the area hangs over the list's first row, where a tap meant for the row would end
    /// the demo without a question, or wake a recorder the app had given up on.
    private static let rim: CGFloat = 8

    /// A line that stays until the reader closes it: cut at three lines, unless it is to be read `inFull`.
    private func report(_ text: String, icon: String, inFull: Bool = false,
                        close: @escaping () -> Void) -> some View {
        strip {
            Image(systemName: icon).font(.footnote)
            Text(text).font(.footnote).lineLimit(inFull ? nil : 3)
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.caption.weight(.semibold))
                    .hitArea(horizontal: 16, vertical: Self.rim)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("閉じる")
        }
    }

    private func strip(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, Self.rim)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            // Faded rather than slid for a reader who has asked for less motion.
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }
}

/// The waking, said inside a sheet, which covers the strip that says it on the screens and is where much of
/// what wakes the recorder is asked for. A recording's sheet has the strip itself instead
/// (`recorderActivity(inSheet:)`), for the wait while the recorder is turned on to play.
struct WakingSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.waking, let busy = model.busy {
            Section {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout)
                }
            }
        }
    }
}

extension View {
    /// Puts the activity strip above a screen's content, inside its navigation stack. `inSheet` for a sheet's
    /// own, which leaves out the demo's strip (see `RecorderActivityBar.inSheet`).
    func recorderActivity(inSheet: Bool = false) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            RecorderActivityBar(inSheet: inSheet)
        }
    }

    /// For a sheet that holds one of a recorder's rows -- a recording, a programme's recordings: closes it
    /// when that recorder's lists are let go of (`AppModel.timesForgotten`). The row is the last recorder's
    /// from then on, and the buttons on the sheet would send its number to the next one. Said in the sheet
    /// rather than by whatever opened it, so that it holds whichever screen that was.
    func closesWithItsRecorder() -> some View {
        closesWithItsDevice(.recorder)
    }

    /// The same for a sheet whose row is either device's -- a reservation: closes it when the lists of the
    /// device that holds the row are let go of, the recorder's as above or the television's
    /// (`AppModel.tvTimesForgotten`). What becomes of the other device is nothing to the row, and leaves the
    /// sheet up.
    func closesWithItsDevice(_ device: DeviceSlot) -> some View {
        modifier(ClosesWithItsDevice(device: device))
    }
}

private struct ClosesWithItsDevice: ViewModifier {
    let device: DeviceSlot
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.onChange(of: device == .tv ? model.tvTimesForgotten : model.timesForgotten) { dismiss() }
    }
}

extension DeviceSlot {
    /// The device's word on the screens, where a row or a sentence has to say which of the two it is about.
    var label: String { self == .tv ? "テレビ" : "レコーダー" }
}

extension PendingQueue.Outcome {
    /// What became of the queue, as the app says it: on the strip, in the notification and in the Shortcuts
    /// action's answer. A home with a recorder alone has one device a sentence can be about, and reads the
    /// sentences it has always read (`summary`). With a television saved the reader has two, so each sentence
    /// says which device the round was for.
    func said(withATelevisionSaved televisionSaved: Bool) -> String? {
        televisionSaved ? says(naming: slot.label) : summary
    }
}

/// What to say when there is no recorder to talk to, in two situations that need different words: nothing has
/// been set up yet, or a recorder is set up and not answering — asleep, or the phone is away from home. Sending
/// someone to correct an address that is already right is worse than saying nothing, which is why looking for
/// the recorder again is offered below 再接続 and not instead of it.
struct NoRecorderView: View {
    let icon: String
    @Environment(AppModel.self) private var model
    @State private var welcoming = false

    /// The tutorial hangs on the whole view rather than on one of its states. Choosing a recorder there
    /// connects, which turns this view to its busy state, and a sheet hung on the state it was opened from
    /// closed with it, in the middle of the connect and before the tutorial could say how it went.
    var body: some View {
        states.sheet(isPresented: $welcoming) { WelcomeView() }
    }

    @ViewBuilder
    private var states: some View {
        if model.host.isEmpty {
            ContentUnavailableView {
                Label("レコーダーが登録されていません", systemImage: icon)
            } description: {
                Text("同じ Wi-Fi 上のレコーダーを探して登録してください")
            } actions: {
                Button("レコーダーを探す") { welcoming = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if let busy = model.busy {
            // While the app is working on it, this is not a failure and should not read as one
            ContentUnavailableView {
                Label(busy, systemImage: icon)
            } description: {
                Text("レコーダーが起きるまで数秒かかります")
            } actions: {
                ProgressView()
            }
        } else if model.connectBlocked {
            // Checking the power and the Wi-Fi, which the last case asks for, would change nothing here.
            ContentUnavailableView {
                Label(LocalNetworkNotice.title, systemImage: "lock.shield")
            } description: {
                Text(LocalNetworkNotice.detail(scanning: false))
            } actions: {
                OpenSettingsButton()
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                Label("レコーダーに接続できません", systemImage: icon)
            } description: {
                // What went wrong when the app knows, since this is where the guide says it now: an address
                // that is not one, or a device there that is not a recorder, is not put right by checking
                // the power.
                Text(model.problem ?? "レコーダーの電源と、同じネットワークに接続されているかを確認してください")
            } actions: {
                VStack(spacing: 12) {
                    // Connecting sends a magic packet by itself when the recorder answered nothing at all, so
                    // there is nothing here about waking: trying again is the whole of it.
                    Button("再接続") { Task { await model.connect() } }
                        .buttonStyle(.borderedProminent)
                    // The address itself may be what is wrong: typed with a digit out -- which is saved all
                    // the same, so the tutorial never comes back by itself -- or given to something else by
                    // the router, where the connect's own look round had no MAC to go by. Quieter than 再接続,
                    // which is still what usually works.
                    Button("レコーダーを探す") { welcoming = true }
                        .buttonStyle(.borderless)
                }
                .disabled(model.jobRunning)
            }
        }
    }
}

/// What to say while local network privacy stands between the app and the recorder. The app cannot tell the
/// system's question still on screen from one answered no, so the words say what is true of both -- access is
/// not allowed, and the app carries on by itself once it is -- and point to the switch for the case where the
/// answer was no, since the question is never asked again.
struct LocalNetworkNotice: View {
    @Environment(AppModel.self) private var model

    static let title = "ローカルネットワークへのアクセスが許可されていません"

    static func detail(scanning: Bool) -> String {
        (scanning ? "許可されると、そのまま検索が始まります。" : "許可されると、そのまま接続します。")
            + "「許可しない」を選んだ場合は、設定アプリの「BD Bridge」で「ローカルネットワーク」をオンにしてください。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(Self.title, systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
            Text(Self.detail(scanning: model.scanBlocked))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// The app's own page in the Settings app, which is where the local network switch is.
struct OpenSettingsButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("設定を開く") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
    }
}

extension View {
    /// A row in a list is tapped anywhere along it, not only on the words. A plain button's hit area is
    /// its content, so a row of short text leaves the rest of the line dead and the tap does nothing,
    /// which reads as the app ignoring you.
    func rowHitArea() -> some View {
        frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    /// A row's lines each as tall as its words need. At the accessibility sizes a list gives a stack of texts
    /// that wrap less height than that: under a title on two lines, the line of small print is cut to one.
    func rowLinesInFull() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }

    /// A small button's tap area grown `inset` points on every side, towards the 44 a finger needs, without
    /// moving it or anything beside it: the area reaches into the space around the button. For the ones drawn
    /// smaller than that -- a tick box, a zoom button -- which otherwise answer only to a tap on the glyph.
    func hitArea(growingBy inset: CGFloat) -> some View {
        hitArea(horizontal: inset, vertical: inset)
    }

    /// The same, grown by different amounts across and up and down. For a button in a strip not much taller
    /// than it: an area reaching past the strip's edge would take the taps meant for the row under it, so up
    /// and down it goes no further than the strip's own padding.
    func hitArea(horizontal: CGFloat, vertical: CGFloat) -> some View {
        padding(.horizontal, horizontal).padding(.vertical, vertical)
            .contentShape(Rectangle())
            .padding(.horizontal, -horizontal).padding(.vertical, -vertical)
    }
}

extension Text {
    /// What stands between the pieces of a row's line of small print, now that the line is one text: two
    /// spaces, about the six points they had between them as views side by side.
    static var rowGap: Text { Text(verbatim: "  ") }
}

extension Color {
    /// The orange of the words and marks that say a programme is reserved, waiting to be sent, or clashing
    /// with another. The system orange is about 2.2:1 against white, too faint for what is often the only
    /// sign on a row that it is reserved. In light mode this is the shade iOS itself switches to under
    /// Increase Contrast; in dark mode the system's own, which already stands out against black.
    static let legibleOrange = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.systemOrange.resolvedColor(with: traits)
            : UIColor(red: 201 / 255, green: 52 / 255, blue: 0, alpha: 1)
    })
}

/// A station's logo set inside a line of text rather than beside it, so that the logo and the words wrap as one
/// line: as a row of separate views, each is squeezed into a column of its own at a large text size.
/// Decorative: the channel's name follows it, and is what VoiceOver reads.
@MainActor
enum InlineLogo {
    /// The logo, `height` points tall, or nil when the station has none. Plenty have none: the recorder only
    /// has the ones it has been sent.
    static func text(_ png: Data?, height: CGFloat) -> Text? {
        guard let png, let image = UIImage(data: png)?.cgImage else { return nil }
        return text(image, height: height)
    }

    /// The logo, or as much blank space when there is none, for a list that lines up what follows it.
    static func holdingSpace(_ png: Data?, height: CGFloat) -> Text {
        text(png, height: height) ?? blank.map { text($0, height: height) } ?? Text("")
    }

    /// A clear image the shape of a logo, which the recorder sends at 64 by 36.
    private static let blank: CGImage? = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 36), format: format).image { _ in }.cgImage
    }()

    private static func text(_ image: CGImage, height: CGFloat) -> Text {
        // An image in a line of text stands on the baseline like a letter, and one as tall as the line then
        // sits above the words beside it. A fifth of its height lower centres it on them.
        Text(Image(decorative: image, scale: CGFloat(image.height) / height).renderingMode(.original))
            .baselineOffset(-height / 5)
    }
}

/// Formatters live here because building one is not free and these are used down long lists.
enum Format {
    static let time: DateFormatter = formatter("HH:mm")
    static let day: DateFormatter = formatter("M/d(E)")
    static let dateTime: DateFormatter = formatter("M/d(E) HH:mm")

    /// When something this app did last happened: "12分前" while it is recent, and the date and time once it is
    /// older than a day. Broadcast times are always Japanese time, wherever the reader is standing; these are
    /// things that happened to this phone, and whether they were recent is a question with no time zone in it.
    static func when(_ date: Date, from now: Date = Date()) -> String {
        guard now.timeIntervalSince(date) < 24 * 3600 else { return dateTime.string(from: date) }
        return date.formatted(.relative(presentation: .named).locale(Locale(identifier: "ja_JP")))
    }

    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = RecorderTime.timeZone
        formatter.dateFormat = pattern
        return formatter
    }

    static func duration(_ seconds: Int) -> String {
        "\(max(0, seconds) / 60)分"
    }

    static func gigabytes(_ bytes: Int) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}
