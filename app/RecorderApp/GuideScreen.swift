import RecorderKit
import SwiftUI

struct GuideScreen: View {
    @Environment(AppModel.self) private var model
    @AppStorage("guideMode") private var mode = "list"
    @State private var tapped: GuideProgramRow?

    private var grid: Bool { mode == "grid" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                if grid {
                    GuideGridView(channels: model.channels, programs: model.programs, day: model.day,
                                  reservationFor: { model.reservation(for: $0) }) { tapped = $0 }
                    .frame(maxHeight: .infinity)
                } else {
                    list
                }
            }
            .navigationTitle("番組表")
            .navigationBarTitleDisplayMode(grid ? .inline : .large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("表示", selection: $mode) {
                        Text("リスト").tag("list")
                        Text("表").tag("grid")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refreshGuide() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!model.connected || model.busy != nil)
                }
            }
            .sheet(item: $tapped) { ProgramSheet(program: $0) }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("放送", selection: Binding(get: { model.broadcasting },
                                              set: { model.broadcasting = $0; reload() })) {
                ForEach(["td", "bs", "cs", "bs4k"], id: \.self) { broadcasting in
                    Text(Codes.broadcastingLabel[broadcasting] ?? broadcasting).tag(broadcasting)
                }
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.days, id: \.timeIntervalSince1970) { day in
                        let selected = Calendar.current.isDate(day, inSameDayAs: model.day)
                        Button(Format.day.string(from: day)) {
                            model.day = day
                            reload()
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(selected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .clipShape(Capsule())
                    }
                }
            }

            HStack {
                if !grid {
                    Menu {
                        Button("すべての局") { model.serviceFilter = nil }
                        ForEach(model.channels) { channel in
                            Button(channel.name) { model.serviceFilter = channel.serviceID }
                        }
                    } label: {
                        Label(model.channelName, systemImage: "line.3.horizontal.decrease")
                            .font(.subheadline)
                    }
                }
                Spacer()
                if let busy = model.busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(shown.count) 件").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var list: some View {
        if let problem = model.problem {
            ContentUnavailableView("うまくいきませんでした", systemImage: "exclamationmark.triangle",
                                   description: Text(problem))
        } else if shown.isEmpty {
            ContentUnavailableView(model.connected ? "この日の番組表がありません" : "レコーダーが未設定です",
                                   systemImage: "calendar",
                                   description: Text(model.connected ? "右上の更新でレコーダーから取得します"
                                                                     : "設定でレコーダーのアドレスを入れてください"))
        } else {
            List(shown) { program in
                Button { tapped = program } label: {
                    ProgramRowView(program: program, logo: logo(for: program.serviceID),
                                   reservation: model.reservation(for: program))
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private var shown: [GuideProgramRow] { model.filteredPrograms }

    private func logo(for serviceID: Int) -> Data? {
        model.channels.first { $0.serviceID == serviceID }?.logo
    }

    private func reload() {
        Task { await model.reloadFromCache() }
    }
}

struct ProgramRowView: View {
    let program: GuideProgramRow
    let logo: Data?
    let reservation: Reservation?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.time.string(from: program.start)).font(.callout.monospacedDigit())
                Text(Format.duration(program.durationSec)).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 52, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                Text(program.title).font(.subheadline).lineLimit(2)
                HStack(spacing: 6) {
                    if let logo, let image = UIImage(data: logo) {
                        Image(uiImage: image).resizable().scaledToFit().frame(height: 12)
                    }
                    Text(program.serviceName).font(.caption2).foregroundStyle(.secondary)
                    if let reservation {
                        Text(reservation.recording ? "録画中" : "予約")
                            .font(.caption2)
                            .foregroundStyle(reservation.recording ? .red : .orange)
                    }
                    if let genre = program.genre?.label {
                        Text(genre).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if !program.summary.isEmpty {
                    Text(program.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
