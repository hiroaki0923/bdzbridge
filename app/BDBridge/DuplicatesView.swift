import RecBridgeModel
import RecorderKit
import SwiftUI

/// Recordings that look like copies of one broadcast. A tick deletes, and whatever is left unticked is marked
/// as kept: the mark follows the ticks rather than the suggestion, so that it can never name a copy that is
/// about to go.
struct DuplicatesView: View {
    let onOpen: (RecordedTitle) -> Void
    @Environment(AppModel.self) private var model
    /// What is ticked, asked and said here: the model's (`DuplicatesState`).
    @State private var state: DuplicatesState

    init(model: AppModel, onOpen: @escaping (RecordedTitle) -> Void) {
        self.onOpen = onOpen
        _state = State(initialValue: DuplicatesState(model: model))
    }

    var body: some View {
        @Bindable var state = state
        Group {
            if model.duplicates.isEmpty {
                prompt
            } else {
                list
            }
        }
        // One alert for both, since two on the same view is not something SwiftUI promises to honour.
        .alert(state.askTitle, isPresented: $state.confirming) {
            if let action = state.actionLabel {
                Button(action, role: .destructive) { state.act() }
                    .disabled(state.holdsTheAction)
            }
            Button(state.closingLabel, role: .cancel) {}
        } message: {
            Text(state.askMessage)
        }
    }

    private var prompt: some View {
        ContentUnavailableView {
            Label(state.promptTitle, systemImage: "square.on.square")
        } description: {
            Text(state.promptDetail)
        } actions: {
            Button(state.scanLabel) { state.scan() }
                .buttonStyle(.borderedProminent)
                .disabled(state.holdsTheScan)
        }
    }

    private var list: some View {
        List {
            Section {
                Text(DuplicatesState.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let unread = state.unreadLine {
                Section {
                    Text(unread).font(.caption).foregroundStyle(.secondary)
                    Button("もう一度調べる") { state.scan() }
                        .disabled(state.holdsScanningAgain)
                }
            }
            ForEach(model.duplicates) { set in
                Section {
                    ForEach(set.items) { title in
                        row(title, in: set)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(set.title).font(.subheadline).textCase(nil).lineLimit(2)
                        Text(state.details(of: set))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            if let label = state.deleteLabel {
                Button(role: .destructive) {
                    state.delete()
                } label: {
                    Text(label)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.holdsDeleting)
                .padding(12)
                .background(.regularMaterial)
            }
        }
    }

    private func row(_ title: RecordedTitle, in set: DuplicateSet) -> some View {
        let deletable = state.deletable(title)
        let keeping = state.keeps(title)
        return HStack(alignment: .top, spacing: 10) {
            Button {
                state.toggle(title)
            } label: {
                // The glyph is little more than 20 points, and a tap had to land on it. The area reaches out
                // from it to about the 44 a finger needs.
                Image(systemName: keeping ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(deletable ? Color.accentColor : .secondary)
                    .hitArea(growingBy: 11)
            }
            .buttonStyle(.plain)
            .disabled(state.holdsTheTick(title))
            // Read out as what the tick does, and whether it is on, rather than as the name of a circle.
            .accessibilityLabel(state.tickLabel(title))
            .accessibilityAddTraits(keeping ? [] : .isSelected)

            Button { onOpen(title) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(state.mark(title))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(keeping ? Color.accentColor.opacity(0.15) : Color.red.opacity(0.12))
                            .foregroundStyle(keeping ? Color.accentColor : .red)
                            .clipShape(Capsule())
                        reason(title, in: set).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(Format.dateTime.string(from: title.start)).font(.footnote)
                    meta(title).font(.caption2).foregroundStyle(.secondary)
                }
                .rowLinesInFull()
                .rowHitArea()
            }
            .buttonStyle(.plain)
        }
    }

    /// Why this copy is kept or not, and the lock when it is protected, as one text that wraps beside the
    /// mark rather than squeezing into columns.
    private func reason(_ title: RecordedTitle, in set: DuplicateSet) -> Text {
        let reason = Text(state.reason(title, in: set))
        guard title.protected else { return reason }
        return reason + Text(verbatim: " ") + Text(Image(systemName: "lock.fill"))
    }

    /// The parts the model gives, as one line of text: as views side by side, a large text size squeezed each
    /// into a narrow column of its own.
    private func meta(_ title: RecordedTitle) -> Text {
        let parts = state.details(of: title).map { Text($0) }
        return parts.dropFirst().reduce(parts[0]) { $0 + Text.rowGap + $1 }
    }
}
