import SwiftUI

/// The state of a sheet that a row of a screen opens -- a programme's, a reservation's, a recording's -- as the
/// screen that keeps it reads it (`OpenRow`): whether a request of its own is out, which holds it open as it holds
/// a sheet, and whether a question or a report of its own is up, which is said where it is shown.
@MainActor
protocol RowSheetState: Identifiable {
    /// A request of its own is out, and what it comes to will be said on it.
    var requestOut: Bool { get }
    /// A question or a report of its own is up.
    var hasSomethingToSay: Bool { get }
}

/// The row a screen has open, with the rule it is kept by. On a compact width, every iPhone's, it is shown in a sheet
/// over the screen; on a regular width, an iPad's, in the system's inspector beside the screen, under the bar
/// (`inspectorColumn`). The state is made by the screen as the row is tapped and handed to either form, rather than
/// made by either, because it outlives the form it is shown in: a window turned between a compact width and a regular
/// one moves it from one to the other as it stands, and a column closed while a request of its own is out leaves it
/// to `closedWhileAsking`.
@MainActor
@Observable
final class OpenRow<Opened: RowSheetState> {
    /// The row open, with what the reader has picked and asked for on it.
    private(set) var opened: Opened?
    /// A row whose column was closed while a request of its own was out, kept until that request ends. The close
    /// cannot be refused: on a narrow iPad the column is the system's overlay, which a tap outside closes and nothing
    /// public holds open. While it waits a tap on any row brings it back (`open`), and what the request comes to is
    /// shown by opening the column on it again (`requestEnded`).
    private(set) var closedWhileAsking: Opened?

    /// Opens a row, in place of the one open -- unless that one has a request of its own out, which holds it as it
    /// holds a sheet: what the request comes to is said there. While a row closed under its request is still waiting
    /// for it, a tap brings that row back instead of opening another: one request at a time, as under a sheet.
    func open(_ make: () -> Opened) {
        guard opened?.requestOut != true else { return }
        if let kept = closedWhileAsking, kept.requestOut {
            opened = kept
            closedWhileAsking = nil
        } else {
            opened = make()
        }
    }

    /// The column's close, by its button or by the system. Always taken, the button being held back while a request
    /// is out; a row closed under one by the system is kept until the request ends.
    func close() {
        if let opened, opened.requestOut { closedWhileAsking = opened }
        opened = nil
    }

    /// Closes the row open for something changed beside it, unless a request of its own is out, which holds it.
    func closeUnlessAsking() {
        guard opened?.requestOut == false else { return }
        opened = nil
    }

    /// The request of a row closed under it has ended. A plain success needs nothing more: the screen shows what
    /// became of the row. Anything the sheet would have put up -- a question, a refusal, a failure -- is on the row,
    /// which opens again to say it.
    func requestEnded() {
        guard let kept = closedWhileAsking, !kept.requestOut else { return }
        closedWhileAsking = nil
        if kept.hasSomethingToSay { opened = kept }
    }

    /// The sheet, on a compact width. What the system writes as it takes the sheet down for the window turning
    /// regular is not a close: the row stays open, in the column.
    func sheetShown(inColumn: Bool) -> Binding<Opened?> {
        Binding(get: { inColumn ? nil : self.opened }, set: { if !inColumn { self.opened = $0 } })
    }

    /// The column, on a regular width, the same the other way round.
    func columnShown(inColumn: Bool) -> Binding<Bool> {
        Binding(get: { inColumn && self.opened != nil }, set: { if !$0, inColumn { self.close() } })
    }
}

extension View {
    /// On a regular width, the row `row` has open beside the screen rather than over it, in the system's inspector,
    /// laid out by `column`. Put inside the tab's navigation stack on what is under the bar, so that the column starts
    /// under the bar rather than beside it.
    func inspectorColumn<Opened: RowSheetState, Column: View>(
        _ row: OpenRow<Opened>, inColumn: Bool, @ViewBuilder column: (Opened) -> Column
    ) -> some View {
        inspector(isPresented: row.columnShown(inColumn: inColumn)) {
            // Empty while the column slides away after a close.
            ZStack {
                if let opened = row.opened {
                    column(opened)
                        // A view of its own for each row, as each sheet is: where the last one was scrolled to,
                        // and anything it had up, are not the next one's.
                        .id(opened.id)
                }
            }
            .inspectorColumnWidth(min: 340, ideal: 400, max: 440)
        }
        .onChange(of: row.closedWhileAsking?.requestOut) { row.requestEnded() }
    }

    /// A column's title and its close, as a row at its top, which the rows scroll under. The column has no bar of its
    /// own -- what is put in a toolbar there goes up into the window's -- so they go here. `held` holds the close
    /// back, as a sheet's is held while a request of its own is out; `close` closes the column, which the system's
    /// dismiss does not.
    func columnTitle(_ title: String, held: Bool, close: @escaping () -> Void) -> some View {
        modifier(ColumnTitle(title: title, held: held, close: close))
    }

    /// The row the column beside its list shows, filled while it is open. Nil is the list's own background.
    func markedOpen(_ open: Bool) -> some View {
        listRowBackground(open ? Color(.systemFill) : nil)
            .accessibilityAddTraits(open ? .isSelected : [])
    }
}

private struct ColumnTitle: ViewModifier {
    let title: String
    let held: Bool
    let close: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            // The system blurs what scrolls under a bar put here, as it does under a navigation bar.
            content.safeAreaBar(edge: .top, spacing: 0) { row }
        } else {
            // Nothing of the system's is drawn behind an inset, and the rows scrolled under it would print over
            // the title.
            content.safeAreaInset(edge: .top, spacing: 0) { row.background(.bar) }
        }
    }

    private var row: some View {
        HStack {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            SheetCloseButton(close: close).disabled(held)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}
