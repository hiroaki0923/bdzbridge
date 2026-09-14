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

    var body: some View {
        TabView(selection: $tab) {
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
