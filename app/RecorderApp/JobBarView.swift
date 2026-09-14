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
                        Button("閉じる") { model.clearJob() }.font(.footnote)
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
                }
                if job.finished, !job.skipped.isEmpty {
                    ForEach(job.skipped.prefix(3)) { skip in
                        Text("・\(skip.reason)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
