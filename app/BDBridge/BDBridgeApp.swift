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

    /// True when the app has been launched only to host `BDBridgeTests`, which run inside it. The app's own
    /// start is left out then: the screens, which start the model, and the overnight task. Started, it would
    /// connect to whatever recorder this simulator last saved -- a real one, on the network the tests run on
    /// -- beside the models the tests make for themselves. XCTest sets this variable in the process it runs
    /// unit tests in; the UI tests launch the app as a process of its own, without it, and it starts as it
    /// would for anybody.
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
        // From the first phase too, not only from changes. A window the system makes again for a process that
        // stayed alive in the background can come up already active, and a bulk job waiting for the app to
        // come back would then wait for good. An ordinary launch has not been away, so nothing connects from
        // here then; `start()` does that.
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
/// for anything reading the screen aloud.
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
    }
}

/// What the app is doing with the recorder, on whatever screen the reader is looking at. Waking takes the
/// better part of ten seconds and the screens otherwise sit there looking broken, so it says so; it appears
/// only while something is under way and slides out when it is done.
struct RecorderActivityBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set for the strip at the top of a sheet. The demo's strip is left to the screen underneath: its 終了
    /// would end the demo under a sheet still showing one of the demo's recordings, whose buttons would then
    /// go to whichever recorder came after it.
    var inSheet = false

    /// Whether any strip is up: what the animation follows. It used to follow `true`, which never changes, so
    /// the strip never slid anywhere. Not which strip it is, nor what it says: one strip taking over from
    /// another -- レコーダーを起動しています giving way to レコーダーに接続していません -- is swapped in place,
    /// where two sliding past each other would show both for a moment.
    private var showing: Bool {
        model.busy != nil || model.flushReport != nil || (model.demo && DemoData.banner && !inSheet)
            || model.connectBlocked || model.gaveUp
    }

    var body: some View {
        // A container that stays when the strip goes, so that the strip's own transition has somewhere to run.
        VStack(spacing: 0) { content }
            .animation(.default, value: showing)
    }

    @ViewBuilder
    private var content: some View {
        if let busy = model.busy {
            strip {
                ProgressView().controlSize(.small)
                Text(busy).font(.footnote)
                Spacer()
            }
        } else if let report = model.flushReport {
            // What became of the reservations that were waiting, whichever screen the app came back to. Ahead
            // of 再接続 below: a flush the recorder walked out of says which were sent, and the strip goes back
            // to offering the reconnect once this is closed.
            strip {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90").font(.footnote)
                Text(report).font(.footnote).lineLimit(3)
                Spacer(minLength: 0)
                Button {
                    model.flushReport = nil
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                        .hitArea(horizontal: 16, vertical: Self.rim)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("閉じる")
            }
        } else if model.demo, DemoData.banner, !inSheet {
            // Said on every screen, because everything on them is invented and a reader who forgets that
            // would take the free space, the recordings and the reservations for their own.
            strip {
                Image(systemName: "theatermasks").font(.footnote)
                Text("サンプルデータを表示しています").font(.footnote)
                Spacer()
                // Not while a connect or a job is under way, which `busy` alone does not always show: see
                // `canChangeRecorder`.
                Button { Task { await model.leaveDemo() } } label: {
                    Text("終了").hitArea(horizontal: 13, vertical: Self.rim)
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(!model.canChangeRecorder)
            }
        } else if model.connectBlocked {
            // Not given up: the app connects the moment the permission comes. Giving it is the one thing the
            // app cannot do, so the strip offers the way to the switch instead of 再接続, which would only
            // run into the same refusal.
            strip {
                Image(systemName: "lock.shield").font(.footnote)
                Text("ローカルネットワークが許可されていません").font(.footnote)
                Spacer()
                OpenSettingsButton()
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        } else if model.gaveUp {
            // The app has stopped trying, and says so rather than leaving a quiet failure to be guessed at
            // from lists that never fill. Trying again is the reader's to ask for: on this network the
            // answer will be the same, and asking costs half a minute of waking a recorder that is not
            // there. It asks by itself only when the network changes.
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
        }
    }

    /// The strip's padding above and below what it says, and so as far as a button's tap area may reach up
    /// and down. Any further and the area hangs below the strip over the list's first row, which on a guide
    /// opened at now is the programme on air: a tap meant for it would end the demo without a question, or
    /// wake a recorder the app had given up on.
    private static let rim: CGFloat = 8

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

/// The waking, said inside a sheet. The strip that says it on the screens is underneath the sheet, and a sheet
/// is where much of what wakes the recorder is asked for -- opening a programme, changing a reservation -- so
/// without this half a minute went by with nothing moving but a greyed-out button. A recording's sheet has the
/// strip itself instead (`recorderActivity(inSheet:)`), for the wait while the recorder is turned on to play.
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
}

/// What to say when there is no recorder to talk to. Two situations that look the same to the code and need
/// different words: nothing has been set up yet, or a recorder is set up and not answering — asleep, or the
/// phone is away from home. Sending someone to Settings to correct an address that is already right is
/// worse than saying nothing, which is why looking for the recorder again is offered below 再接続 and not
/// instead of it.
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
                    // the router, where the connect's own look round had no MAC to go by. The way back was
                    // otherwise only in the settings. Quieter than 再接続, which is still what usually works.
                    Button("レコーダーを探す") { welcoming = true }
                        .buttonStyle(.borderless)
                }
                .disabled(model.jobRunning)
            }
        }
    }
}

/// What to say while local network privacy stands between the app and the recorder. The words have to be
/// right in two situations the app cannot tell apart: the system's question is on screen and not answered
/// yet, or it was answered no. So they say what is true of both -- access is not allowed -- say that the app
/// carries on by itself once it is, and point to the switch for the case where the answer was no, since
/// the question is never asked again.
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

    /// A row's lines each as tall as its words need. A list gave a stack of texts that wrap less height than
    /// that at the accessibility sizes: under a title on two lines, the line of small print was cut to one
    /// ending in an ellipsis, with a blank below it where its second line should have been.
    func rowLinesInFull() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }

    /// A small button's tap area grown `inset` points on every side, towards the 44 a finger needs, without
    /// moving it or anything beside it: the area reaches into the space around the button instead of taking
    /// more of the layout. For the ones drawn smaller than that -- a tick box, a zoom button -- which
    /// otherwise answer only to a tap on the glyph itself.
    func hitArea(growingBy inset: CGFloat) -> some View {
        hitArea(horizontal: inset, vertical: inset)
    }

    /// The same, grown by different amounts across and up and down. For a button in a strip not much taller
    /// than it: an area reaching past the strip's edge lands on whatever is under the strip, and the strip is
    /// drawn in front, so it takes the taps meant for the row there. Up and down it goes no further than the
    /// strip's own padding.
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

/// A station's logo set inside a line of text rather than beside it. Beside it, the line was a row of separate
/// views, and at a large text size each was squeezed into a column of its own -- サン / プル / テレビ. In the
/// text, the logo and the words wrap as one line. Decorative: the channel's name follows it, and is what
/// VoiceOver reads.
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
        // sits above the words beside it. A fifth of its height lower centres it on them, as the row's
        // HStack used to.
        Text(Image(decorative: image, scale: CGFloat(image.height) / height).renderingMode(.original))
            .baselineOffset(-height / 5)
    }
}

/// Formatters live here because building one is not free and these are used down long lists.
enum Format {
    static let time: DateFormatter = formatter("HH:mm")
    static let day: DateFormatter = formatter("M/d(E)")
    static let dateTime: DateFormatter = formatter("M/d(E) HH:mm")

    /// When something this app did last happened: "12分前" while it is recent, and the date and time once it
    /// is older than a day.
    ///
    /// Broadcast times are always Japanese time -- the recorder is in Japan and records to a Japanese clock,
    /// so a programme at 20:00 is at 20:00 wherever the reader is standing. These are not broadcast times
    /// though; they are things that happened to this phone, and what matters about them is whether they
    /// were recent, which is a question with no time zone in it at all.
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
