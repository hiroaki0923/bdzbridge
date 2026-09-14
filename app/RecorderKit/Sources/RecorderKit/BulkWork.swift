import Foundation

/// What happened to one recording in a run of many.
public enum ItemOutcome: Sendable, Equatable {
    case changed
    case skipped(reason: String)

    public var reason: String? {
        if case .skipped(let reason) = self { return reason }
        return nil
    }
}

/// Deleting and protecting, one recording at a time. The loop around these belongs to the caller, which is
/// what gives it the progress and the stop button; what lives here is the decision about each recording,
/// including the recorder's two traps.
public extension RecorderClient {
    /// The recorder refuses a protected recording, and answers success for an id it no longer has. So the
    /// recording is asked about first: an id the recorder does not know comes back as UPnP error 820, which
    /// means it went away on its own and there is nothing to report as an error.
    func deleteIfPresent(_ title: RecordedTitle) async -> ItemOutcome {
        if title.protected { return .skipped(reason: "保護されています") }

        do {
            _ = try await titleDetail(id: title.id)
        } catch let error as RecorderError {
            if case .soap(_, _, "820", _) = error { return .skipped(reason: "すでにありません") }
        } catch {
            // anything else here is not worth giving up on; the delete below will say what went wrong
        }

        do {
            try await deleteTitle(id: title.id)
            return .changed
        } catch let error as RecorderError {
            return .skipped(reason: error.explanation)
        } catch {
            return .skipped(reason: String(describing: error))
        }
    }

    /// Nothing is sent when the recording is already the way it should be.
    func setProtected(_ title: RecordedTitle, _ on: Bool) async -> ItemOutcome {
        if title.protected == on {
            return .skipped(reason: on ? "すでに保護されています" : "保護されていません")
        }
        do {
            try await updateTitle(id: title.id, protected: on)
            return .changed
        } catch let error as RecorderError {
            return .skipped(reason: error.explanation)
        } catch {
            return .skipped(reason: String(describing: error))
        }
    }
}
