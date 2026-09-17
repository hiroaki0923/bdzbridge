import RecorderKit
import SwiftUI

@main
struct BDBridgeApp: App {
    @State private var model = AppModel()

    init() {
        BackgroundWork.register()
        BackgroundWork.schedule()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    /// `-startTab reservations` on the command line opens that tab, which is how the screens are checked in a
    /// simulator without tapping through them.
    @State private var tab = UserDefaults.standard.string(forKey: "startTab") ?? "guide"
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.returnedToForeground() } }
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

/// Formatters live here because building one is not free and these are used down long lists.
@MainActor
/// What to say when there is no recorder to talk to. Two situations that look the same to the code and need
/// different words: nothing has been set up yet, or a recorder is set up and not answering — asleep, or the
/// phone is away from home. Sending someone to Settings to correct an address that is already right is
/// worse than saying nothing.
/// What the app is doing with the recorder, on whatever screen the reader is looking at. Waking takes the
/// better part of ten seconds and the screens otherwise sit there looking broken, so it says so; it appears
/// only while something is under way and slides out when it is done.
struct RecorderActivityBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let busy = model.busy {
            strip {
                ProgressView().controlSize(.small)
                Text(busy).font(.footnote)
                Spacer()
            }
        } else if model.demo, DemoData.banner {
            // Said on every screen, because everything on them is invented and a reader who forgets that
            // would take the free space, the recordings and the reservations for their own.
            strip {
                Image(systemName: "theatermasks").font(.footnote)
                Text("サンプルデータを表示しています").font(.footnote)
                Spacer()
                Button("終了") { Task { await model.leaveDemo() } }
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
                Button("再接続") { Task { await model.connect() } }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        }
    }

    private func strip(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

extension View {
    /// Puts the activity strip above a screen's content, inside its navigation stack.
    func recorderActivity() -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            RecorderActivityBar().animation(.default, value: true)
        }
    }
}

struct NoRecorderView: View {
    let icon: String
    @Environment(AppModel.self) private var model
    @State private var welcoming = false

    var body: some View {
        if model.host.isEmpty {
            ContentUnavailableView {
                Label("レコーダーが登録されていません", systemImage: icon)
            } description: {
                Text("同じ Wi-Fi 上のレコーダーを探して登録してください")
            } actions: {
                Button("レコーダーを探す") { welcoming = true }
                    .buttonStyle(.borderedProminent)
            }
            .sheet(isPresented: $welcoming) { WelcomeView() }
        } else if let busy = model.busy {
            // While the app is working on it, this is not a failure and should not read as one
            ContentUnavailableView {
                Label(busy, systemImage: icon)
            } description: {
                Text("レコーダーが起きるまで数秒かかります")
            } actions: {
                ProgressView()
            }
        } else {
            ContentUnavailableView {
                Label("レコーダーに接続できません", systemImage: icon)
            } description: {
                Text("レコーダーの電源と、同じネットワークに接続されているかを確認してください")
            } actions: {
                // Connecting sends a magic packet by itself when the recorder answered nothing at all, so
                // there is nothing here about waking: trying again is the whole of it.
                Button("再接続") { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent)
            }
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
}

enum Format {
    static let time: DateFormatter = formatter("HH:mm")
    static let day: DateFormatter = formatter("M/d(E)")
    static let dateTime: DateFormatter = formatter("M/d(E) HH:mm")

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
