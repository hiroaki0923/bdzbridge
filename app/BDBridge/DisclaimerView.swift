import RecBridgeModel
import SwiftUI

/// What the reader should know before this app writes to their recorder (`Disclaimer`), laid out.
struct DisclaimerView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(Disclaimer.opening)

                    ForEach(Disclaimer.sections, id: \.heading) { section($0.heading, $0.body) }
                    Link(Disclaimer.sourceLink, destination: URL(string: Disclaimer.sourceURL)!)
                        .font(.callout)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(Disclaimer.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseButton() }
        }
    }

    private func section(_ heading: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(.headline)
            Text(body).foregroundStyle(.secondary)
        }
    }
}
