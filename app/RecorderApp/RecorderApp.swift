import RecorderKit
import SwiftUI

@main
struct RecorderApp: App {
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
    /// `-startTab reservations` on the command line opens that tab, which is how the screens are checked in a
    /// simulator without tapping through them.
    @State private var tab = UserDefaults.standard.string(forKey: "startTab") ?? "guide"

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
        .task { await model.start() }
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
struct NoRecorderView: View {
    let icon: String
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.host.isEmpty {
            ContentUnavailableView("レコーダーが未設定です", systemImage: icon,
                                   description: Text("設定でレコーダーのアドレスを入れてください"))
        } else {
            ContentUnavailableView {
                Label("レコーダーにつながりません", systemImage: icon)
            } description: {
                Text("電源が入っているか、同じネットワークにいるかを確かめてください")
            } actions: {
                // Connecting sends a magic packet by itself when the recorder answered nothing at all, so
                // there is nothing here about waking: trying again is the whole of it.
                Button("もう一度つないでみる") { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy != nil)
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
