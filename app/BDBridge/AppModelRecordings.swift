import Foundation
import RecorderKit
import SwiftUI

/// Recordings: the list, its orders and groups, one recording's details, protecting, deleting and
/// playing it, and powering the recorder on.
extension AppModel {
    // MARK: - recordings

    enum TitleSort: String, CaseIterable {
        case newest, oldest, largest

        var label: String {
            switch self {
            case .newest: "新しい順"
            case .oldest: "古い順"
            case .largest: "大きい順"
            }
        }
    }

    func loadTitles(force: Bool = false) async {
        await start()
        await loadTitlesNow(force: force)
    }

    /// The load itself, without `start()`, for anything `connect()` reaches: see there. The read is the driver's
    /// (`RecorderDriver.titles`), which hands the list over as it comes back, before the free space is read.
    func loadTitlesNow(force: Bool) async {
        guard client != nil, !unreachable, force || !titlesLoaded else { return }
        _ = await recorderDriver?.titles { list in
            self.titles = list
            self.titlesLoaded = true
            // The sets on screen were built from the list as it was. A copy one says it keeps may have gone
            // since, and deleting the others would then leave nothing.
            if !self.duplicates.isEmpty { self.recomputeDuplicates() }
        }
    }

    /// The recordings the screen is showing: filtered, then sorted.
    var shownTitles: [RecordedTitle] {
        var shown = titles
        if let titleGenre { shown = shown.filter { $0.genre?.level1 == titleGenre } }
        if let titleState { shown = shown.filter { $0.watchState == titleState } }
        switch titleSort {
        case .newest: shown.sort { $0.start > $1.start }
        case .oldest: shown.sort { $0.start < $1.start }
        case .largest: shown.sort { ($0.sizeMB ?? 0) > ($1.sizeMB ?? 0) }
        }
        return shown
    }

    var titleGroups: [TitleGroup] { TitleGroup.group(shownTitles) }

    /// How many recordings each genre holds, for the filter row.
    var titleGenreCounts: [Int: Int] {
        Dictionary(titles.compactMap { $0.genre?.level1 }.map { ($0, 1) }, uniquingKeysWith: +)
    }

    func members(of group: TitleGroup) -> [RecordedTitle] {
        shownTitles.filter { $0.seriesKey == group.key }
    }

    func channelName(for title: RecordedTitle) -> String {
        channelNames["\(title.broadcastingType)-\(title.serviceID)"]
            ?? Codes.broadcastingLabel[Codes.broadcasting(code: title.broadcastingType) ?? ""]
            ?? ""
    }

    /// Asked as a recording's sheet opens, which is also the moment to wake a recorder that has gone to
    /// sleep: what the reader opened it for -- playing, protecting, deleting -- then goes straight through.
    func detail(of title: RecordedTitle) async -> (summary: String, details: [String])? {
        await start()
        guard let client, !unreachable, await wakeIfDozing() else { return nil }
        do {
            return try await client.titleDetail(id: title.id)
        } catch let error as any DeviceError where error.failure == .silent {
            // Nothing on the strip says this is out, so another recorder can be chosen meanwhile, and a connect
            // can make a new client. Silence met by a client the model no longer holds says nothing of the
            // recorder in play, and is not taken for its own.
            if client === self.client { lostTheRecorder() }
            return nil
        } catch {
            return nil
        }
    }

    /// A write: the recorder stops deleting this one to make room.
    @discardableResult
    func setProtected(_ title: RecordedTitle, _ on: Bool) async -> Bool {
        await start()
        guard let client else { return false }
        let done = await run(on ? "保護中" : "保護を解除中", sending: true) {
            try await client.updateTitle(id: title.id, protected: on)
            if let index = self.titles.firstIndex(where: { $0.id == title.id }) {
                self.titles[index].protected = on
            }
        }
        // Silence may have come after the recorder made the change. The list is read again once it answers,
        // rather than guessed at.
        if !done, unreachable { titlesLoaded = false }
        // which copy of a set to keep can change with it
        if done, !duplicates.isEmpty { recomputeDuplicates() }
        return done
    }

    /// A write, and not one that can be undone: the recording is gone from the recorder.
    @discardableResult
    func delete(_ title: RecordedTitle) async -> Bool {
        await start()
        // The recorder answers a bare HTTP 500 for a recording it is still writing to, which on screen
        // reads as a fault in the app. The screens do not offer it, but a row can be a few minutes old.
        if title.recording {
            problem = "録画中のため削除できません。番組が終わるまでお待ちください。"
            return false
        }
        guard let client else { return false }
        let deleted = await run("削除中", sending: true) {
            try await client.deleteTitle(id: title.id)
            self.titles.removeAll { $0.id == title.id }
            // Under the same line, but not able to fail the delete, which has happened whatever this says:
            // see `refreshStorage`.
            await self.refreshStorage(client)
        }
        // as for protecting: silence may have come after the recording had gone
        if !deleted, unreachable { titlesLoaded = false }
        // A set on screen may have been left with one copy, or none of the one it says it keeps.
        if deleted, !duplicates.isEmpty { recomputeDuplicates() }
        return deleted
    }

    /// Playback happens on the television the recorder is attached to, not here. `pause` toggles, so the same
    /// call resumes.
    ///
    /// Playing turns a recorder in network standby on first and waits for it (`RecorderClient.play`), saying on
    /// the line how long it has been. One still not on by the end of the wait, or a pause or a stop sent to one
    /// in standby, answers 880, which is what `needsPower` reports and the sheet offers to turn it on for.
    func play(_ title: RecordedTitle, _ operation: String) async {
        await start()
        guard let client else { return }
        session.powerNeeded(false)
        await run(operation == "stop" ? "停止中" : "再生を指示中") { activity in
            do {
                if operation == "play" {
                    try await client.play(titleID: title.id) { @MainActor seconds in
                        self.activities.update(activity, to: Self.poweringOnLine(seconds))
                    }
                } else {
                    try await client.playControl(titleID: title.id, operation: operation)
                }
            } catch let error as any DeviceError where error.failure == .needsPower {
                self.session.powerNeeded(true)
                throw error
            }
        }
    }

    private static func poweringOnLine(_ seconds: Int) -> String {
        "レコーダーの電源を入れています（\(seconds) 秒）"
    }

    /// Turns the recorder on, which also turns on the television attached to it.
    func powerOn() async {
        await start()
        guard let client else { return }
        await run("電源を入れています") {
            _ = try await client.powerOn()
            self.session.powerNeeded(false)
        }
    }
}
