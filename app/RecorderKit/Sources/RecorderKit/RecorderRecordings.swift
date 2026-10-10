import Foundation

/// What is asked of the recorder's recordings, beside its reservations: reading them with the free space, one
/// recording's details, and protecting and deleting one. The steps, and what each says on the host's screen; what
/// the app keeps of the list is handed to it as the step that changes it goes through (`keep`), and the screens
/// are the app's.
extension RecorderDriver {
    // MARK: - the list and the free space

    /// The line on screen while the recordings are read.
    static let titlesLine = "録画一覧を取得中"

    /// Reads every recording, in pages of 200, and then the free space, which is read again with the list. One
    /// operation, as `DeviceLink.run` makes one: under a line of its own, the recorder made sure of first, the
    /// list read on the client in hand at the door, which is the one the check is asked with. Whether the list
    /// was read; when it was not, the host's line says why, as for any read.
    ///
    /// The list is handed to `keep` as it comes back, before the free space is asked, so that what the app holds
    /// is the list from the moment it is read. The free space is only shown, and cannot fail the list: a
    /// recorder that will not say leaves it unknown (`storage(of:)`), and silence loses the recorder, saying
    /// nothing (`learnTheFreeSpace`). The line of what went wrong is cleared once both are over.
    ///
    /// Nothing is asked when there is no recorder's client; whether to ask at all -- the recorder known to be
    /// away, the list read already -- is the app's to say.
    public func titles(keep: @MainActor ([RecordedTitle]) -> Void) async -> Bool {
        guard let link, let client = link.client as? RecorderClient else { return false }
        return await asked(Self.titlesLine, on: link) { _ in
            keep(try await client.allTitles())
            await self.learnTheFreeSpace(on: client, link)
        } != nil
    }

    /// The free space read again, after a delete or with the list of recordings, and kept in the session for
    /// the screens. It is only shown, so a recorder that will not say is not an error. Silence is still silence,
    /// and loses the recorder, with nothing said.
    func learnTheFreeSpace(on client: RecorderClient, _ link: DeviceLink) async {
        do {
            link.session.learned(storage: try await Self.storage(of: client))
        } catch {
            link.lost()
        }
    }

    // MARK: - one recording

    /// What the recorder says a recording is about, or nil when it was not asked or could not say. Asked as a
    /// recording's sheet opens, which is also the moment to wake a recorder that has gone to sleep: what the
    /// reader opened it for -- playing, protecting, deleting -- then goes straight through.
    ///
    /// No line of its own, as the question of what a reservation would clash with (`conflicts`): it is asked
    /// before anybody has asked for anything, and the line of what went wrong is left as it is, whatever the
    /// answer. With no recorder's client, or the recorder silent at the last ask, nothing is asked. The recorder
    /// is made sure of first (`DeviceLink.ensureUp`), on the client in hand at the door. Silence loses the
    /// recorder and says nothing, unless the link asks through another client by then: nothing on the strip
    /// says this is out, so another recorder can be chosen meanwhile, and a connect can make a new client, and
    /// silence met by a client the link no longer holds says nothing of the recorder in play. Anything else is
    /// no details, said nowhere.
    public func detail(of title: RecordedTitle) async -> (summary: String, details: [String])? {
        guard let link, let client = link.client as? RecorderClient, !link.session.unreachable,
              await link.ensureUp() else { return nil }
        do {
            return try await client.titleDetail(id: title.id)
        } catch let error as any DeviceError where error.failure == .silent {
            if client === link.client { link.lost() }
            return nil
        } catch {
            return nil
        }
    }

    /// The lines on screen while a recording is protected, or its protection taken off, and while one is deleted.
    static let protectingLine = "保護中"
    static let unprotectingLine = "保護を解除中"
    static let deletingTitleLine = "削除中"

    /// Said when a recording still being recorded is asked to be deleted.
    static let stillRecording = "録画中のため削除できません。番組が終わるまでお待ちください。"

    /// A write: the recorder stops deleting this one to make room. Whether it went through; `keep` is how the
    /// app's list shows it, called once the recorder has taken it. With no recorder's client, it fails with
    /// nothing said. Otherwise one operation, as `DeviceLink.run` makes one, on the client in hand at the door:
    /// silence says that the protect may have arrived (`mayHaveArrived`), and anything else in the recorder's
    /// words.
    public func protect(_ title: RecordedTitle, _ on: Bool, keep: @MainActor () -> Void) async -> Bool {
        guard let link, let client = link.client as? RecorderClient else { return false }
        return await asked(on ? Self.protectingLine : Self.unprotectingLine, sending: Self.mayHaveArrived,
                           on: link) { _ in
            try await client.updateTitle(id: title.id, protected: on)
            keep()
        } != nil
    }

    /// A write, and not one that can be undone: the recording is gone from the recorder. Whether it went through;
    /// `keep` takes the row out of the app's list, called once the recorder has taken it, before the free space
    /// is read again under the same line (`learnTheFreeSpace`), which cannot fail the delete: it has happened
    /// whatever that says.
    ///
    /// The recorder answers a bare HTTP 500 for a recording it is still writing to, which on screen reads as a
    /// fault in the app. The screens do not offer it, but a row can be a few minutes old: one still being
    /// recorded is turned away before anything is sent, and the line says why (`stillRecording`). Then as
    /// `protect`: no recorder's client fails with nothing said, and silence says that the delete may have
    /// arrived.
    public func delete(_ title: RecordedTitle, keep: @MainActor () -> Void) async -> Bool {
        guard let link else { return false }
        if title.recording {
            link.owner?.problem = Self.stillRecording
            return false
        }
        guard let client = link.client as? RecorderClient else { return false }
        return await asked(Self.deletingTitleLine, sending: Self.mayHaveArrived, on: link) { _ in
            try await client.deleteTitle(id: title.id)
            keep()
            await self.learnTheFreeSpace(on: client, link)
        } != nil
    }

    // MARK: - one request

    /// One thing the reader asked of the recorder, as `DeviceLink.run` makes it, written out so that what is asked
    /// in it can be the operation's own: under `line`, the recorder made sure of first (`DeviceLink.check`),
    /// then `work`, handed the line's token. What `work` returned, or nil when the check said no -- it has said
    /// why -- or `work` failed, which is said (`DeviceLink.say`): `sending` is the sentence for silence met by
    /// what changes the recorder, nil for a read. Going through clears the line of what went wrong, once `work`
    /// is over.
    ///
    /// `work` asks the client in hand at the operation's door, which is the one the check is asked with: nothing
    /// suspends between the door and the check.
    func asked<T>(_ line: String, sending: String? = nil, on link: DeviceLink,
                  _ work: @MainActor (Activities.Token?) async throws -> T) async -> T? {
        let owner = link.owner
        return await link.underALine(line) { token in
            guard case .up = await link.check() else { return nil }
            do {
                let value = try await work(token)
                owner?.problem = nil
                return value
            } catch {
                _ = link.say(OperationFailure(error, sending: sending), ofARead: sending == nil)
                return nil
            }
        }
    }
}
