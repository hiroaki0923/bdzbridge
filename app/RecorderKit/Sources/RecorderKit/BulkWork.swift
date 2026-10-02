import Foundation

/// What happened to one recording in a run of many.
public enum ItemOutcome: Sendable, Equatable {
    case changed
    /// The recorder no longer had it: deleted there since the list was read. Nothing went wrong, and the
    /// caller's list should stop showing it. A case of its own so that the caller need not tell it from the
    /// other reasons by the words of the sentence.
    case gone
    case skipped(reason: String)

    /// Why nothing was changed, for the run's list of what it passed over. Nil when something was.
    public var reason: String? {
        switch self {
        case .changed: nil
        case .gone: "すでに削除されています"
        case .skipped(let reason): reason
        }
    }
}

/// What asking the recorder for one recording's programme text came to, for the duplicate scan.
public enum SummaryRead: Sendable, Equatable {
    /// What the recorder holds. An empty text is an answer too: some recordings come with none.
    case read(String)
    /// UPnP error 820: the recorder no longer has the recording.
    case gone
    /// The recorder answered, but not with the text, and this is why.
    case failed(reason: String)
}

/// Deleting, protecting and reading the programme text, one recording at a time. The loop around these
/// belongs to the caller, which is what gives it the progress and the stop button; what lives here is the
/// decision about each recording, including the recorder's two traps.
///
/// Silence is thrown rather than reported as a skip: a recorder gone to sleep part way through would otherwise
/// turn every recording left into a skip of its own, each after a thirty-second timeout. The caller stops at
/// the first, and does not send that recording again: a write that met silence may have arrived all the same.
public extension RecorderClient {
    /// The recorder refuses a protected recording, and answers success for an id it no longer has. So the
    /// recording is asked about first: an id the recorder does not know comes back as UPnP error 820, which
    /// means it went away on its own and there is nothing to report as an error.
    func deleteIfPresent(_ title: RecordedTitle) async throws -> ItemOutcome {
        if title.protected { return .skipped(reason: "保護されています") }
        // The recorder answers a bare HTTP 500 for one it is still writing to, which reads as a fault in the
        // app rather than as the one thing it is: wait until the programme has finished.
        if title.recording { return .skipped(reason: "録画中です") }

        do {
            _ = try await titleDetail(id: title.id)
        } catch let error as RecorderError {
            if case .soap(_, _, "820", _) = error { return .gone }
            // nothing has been deleted yet, but the delete would only wait out the same silence
            if error.unreachable { throw error }
        } catch {
            // anything else here is not worth giving up on; the delete below will say what went wrong
        }

        do {
            try await deleteTitle(id: title.id)
            return .changed
        } catch let error as RecorderError where error.unreachable {
            throw error
        } catch let error as RecorderError {
            return .skipped(reason: error.explanation)
        } catch {
            return .skipped(reason: String(describing: error))
        }
    }

    /// The text the duplicate scan compares, and caches for good, so only what the recorder actually said
    /// counts as read: two failures kept as empty texts would agree with each other and come up as copies.
    func summary(of id: String) async throws -> SummaryRead {
        do {
            return .read(try await titleDetail(id: id).summary)
        } catch let error as RecorderError where error.unreachable {
            throw error
        } catch let error as RecorderError {
            if case .soap(_, _, "820", _) = error { return .gone }
            return .failed(reason: error.explanation)
        } catch {
            return .failed(reason: String(describing: error))
        }
    }

    /// Nothing is sent when the recording is already the way it should be.
    func setProtected(_ title: RecordedTitle, _ on: Bool) async throws -> ItemOutcome {
        if title.protected == on {
            return .skipped(reason: on ? "すでに保護されています" : "保護されていません")
        }
        do {
            try await updateTitle(id: title.id, protected: on)
            return .changed
        } catch let error as RecorderError where error.unreachable {
            throw error
        } catch let error as RecorderError {
            return .skipped(reason: error.explanation)
        } catch {
            return .skipped(reason: String(describing: error))
        }
    }
}
