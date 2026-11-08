import RecBridgeModel
import RecorderKit
import SwiftUI

/// Which channels the guide shows, and in what order, one broadcasting type at a time. The cache keeps the
/// reader's choice (`GuideStore.setChannelPreferences`), and the list, the grid and the search follow it. A
/// broadcasting type easily has sixty channels, most of them never watched, and the grid is read across them.
///
/// Only this phone's guide changes. The recorder is not told, the reservations and recordings lists show
/// every channel as before, and a hidden channel records as it always did.
struct ChannelsScreen: View {
    @State private var channels: ChannelsState
    @State private var confirmingReset = false

    init(broadcasting: String, model: AppModel) {
        _channels = State(initialValue: ChannelsState(broadcasting: broadcasting, model: model))
    }

    var body: some View {
        List {
            if !channels.channels.isEmpty {
                Section {
                    ForEach(channels.channels) { channel in
                        ChannelRow(channel: channel, shown: Binding(get: { channels.isShown(channel) },
                                                                    set: { channels.show(channel, $0) }))
                    }
                    .onMove { channels.move(from: $0, to: $1) }
                } footer: {
                    Text(ChannelsState.footer)
                }
                Section {
                    Button("レコーダーの順に戻して、すべて表示") { confirmingReset = true }
                        .disabled(!channels.customised)
                        // On the button, which is where the question then points from.
                        .confirmationDialog(channels.resetQuestion, isPresented: $confirmingReset,
                                            titleVisibility: .visible) {
                            Button("レコーダーの順に戻す") { channels.reset() }
                        }
                }
            }
        }
        // Always editing, so that every row shows its handle. A reorder behind an 編集 button is one that few
        // would find, and there is nothing else on this screen for the button to switch away from.
        .environment(\.editMode, .constant(.active))
        .overlay {
            if channels.loaded, channels.channels.isEmpty {
                ContentUnavailableView(channels.empty.title, systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text(channels.empty.detail ?? ""))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { typePicker }
        .navigationTitle("チャンネルの表示と並び順")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: channels.source) { await channels.load() }
        .alert("保存できませんでした", isPresented: Binding(get: { channels.failure != nil },
                                                    set: { if !$0 { channels.failure = nil } })) {
            Button("OK") { channels.failure = nil }
        } message: {
            Text(channels.failure?.asABody ?? "")
        }
    }

    private var typePicker: some View {
        @Bindable var channels = channels
        return Picker("放送", selection: $channels.broadcasting) {
            ForEach(channels.types, id: \.self) { type in
                Text(Codes.broadcastingShortLabel[type] ?? type).tag(type)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The same over the guide, opened from its channel menu or from an empty guide with every channel hidden.
struct ChannelsSheet: View {
    let broadcasting: String
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ChannelsScreen(broadcasting: broadcasting, model: model)
                .toolbar { SheetCloseButton() }
        }
    }
}

private struct ChannelRow: View {
    let channel: Channel
    @Binding var shown: Bool

    var body: some View {
        Toggle(isOn: $shown) {
            HStack(spacing: 10) {
                // The space is held where a station has no logo, so that the names line up.
                Group {
                    if let logo = channel.logo, let image = UIImage(data: logo) {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 36, height: 18)
                .accessibilityHidden(true)
                Text(channel.name)
                    .foregroundStyle(shown ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
    }
}
