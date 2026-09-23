import SwiftUI

/// The bulk job, wherever the reader happens to be looking. It is shown on the recordings screen and inside
/// the sheets, so closing a sheet never takes away the way to stop what it started.
struct JobBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let job = model.job {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if job.finished {
                        Text(job.outcome).font(.footnote)
                        Spacer()
                        Button {
                            model.clearJob()
                        } label: {
                            Image(systemName: "xmark").font(.caption.weight(.bold))
                                .hitArea(horizontal: 16, vertical: Self.rim)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("閉じる")
                    } else {
                        ProgressView().controlSize(.small)
                        Text("\(job.verb)中 \(job.done) / \(job.total)").font(.footnote)
                        if job.cancelled { Text("中止します…").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("中止") { model.cancelBulk() }
                            .font(.footnote)
                            .disabled(job.cancelled)
                    }
                }
                if !job.finished {
                    ProgressView(value: job.progress)
                    // Said while it runs, since nothing can say it once the reader has gone: iOS suspends the
                    // app soon after it leaves, so the job finishes the recording it is on and waits there.
                    Text("アプリを離れると一時停止し、戻ると再開します")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if job.finished, !job.skipped.isEmpty {
                    ForEach(job.skipped.prefix(3)) { skip in
                        Text("・\(skip.reason)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, Self.rim)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    /// The bar's padding above and below, and so as far as the ✕'s tap area may reach up and down. Any
    /// further and the area hangs past the bar's edge over the list, whose row there would lose its taps.
    private static let rim: CGFloat = 8
}
