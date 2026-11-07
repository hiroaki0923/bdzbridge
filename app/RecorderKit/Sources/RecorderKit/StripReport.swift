import Foundation

/// The report the strip at the foot of the screens holds of what the sendings to the devices came to, until the
/// reader closes it: how a sending's sentences are added to what is there unread, and how the count of
/// reservations held for another recorder, which a recorder's report begins with, is replaced at each sending.
public enum StripReport {
    /// What a sending said, added to a report the reader has not closed (`unread`): its sentences after what is
    /// there, and only those the report does not hold already -- a row passed over at every sending would add its
    /// own at each connect and each pull-down. The report as it reads with them added, or nil when nothing is to
    /// be added and the report stays as it was.
    public static func adding(_ said: String, toUnread unread: String?) -> String? {
        let held = unread.map(sentences) ?? []
        let new = sentences(said).filter { !held.contains($0) }
        return new.isEmpty ? nil : ([unread].compactMap { $0 } + new).joined(separator: "。")
    }

    /// A recorder's report after a sending: the count of what is held for another recorder first, for as long as
    /// any is (`held`), in the place of the count it began with before (`heldBefore`), then what the report held
    /// unread with what the sending said added (`said`, nil for a sending with nothing to say). Nil when there is
    /// nothing to say at all, and the report stays as it was; otherwise the report, and the count it begins with
    /// now, to be replaced in its turn.
    public static func afterASending(report: String?, heldBefore: String?, held: String?,
                                     said: String?) -> (report: String, held: String?)? {
        var unread = report
        if let heldBefore, let report, report.hasPrefix(heldBefore) {
            let rest = report.dropFirst(heldBefore.count).drop { $0 == "。" }
            unread = rest.isEmpty ? nil : String(rest)
        }
        let added = said.flatMap { adding($0, toUnread: unread) }
        let lines = [held, added ?? unread].compactMap { $0 }
        guard !lines.isEmpty else { return nil }
        return (lines.joined(separator: "。"), held)
    }

    /// The sentences of what a sending said, which joins them with a full stop. Cut at each full stop that is not
    /// inside a title's brackets: a programme's title can have one of its own.
    static func sentences(_ said: String) -> [String] {
        var sentences = [""], depth = 0
        for character in said {
            if character == "「" { depth += 1 } else if character == "」" { depth = max(depth - 1, 0) }
            if character == "。", depth == 0 {
                sentences.append("")
            } else {
                sentences[sentences.count - 1].append(character)
            }
        }
        return sentences.filter { !$0.isEmpty }
    }
}

public extension Array where Element == RecordedTitle {
    /// The list to hold after a read of the recordings (`read`), with the USB disk the read holds the rows of
    /// (`disk`), `usb` being the disk known now. A read that holds no USB disk's rows takes away only those of a
    /// disk that has left the slot: the rows of one still there were not read this time, which says nothing of
    /// them, and they stay, so that a pull-down that met a busy recorder does not empty a list narrowed to that
    /// disk, nor undo a set of copies.
    func keeping(_ read: [RecordedTitle], readFrom disk: RecorderDisk?, usb: RecorderDisk?) -> [RecordedTitle] {
        let held = disk == nil ? filter { $0.readFrom?.isStill(usb) == true } : []
        return held.isEmpty ? read : read.filter { $0.destination != RecorderDisk.usbID } + held
    }

    /// Whether this list, read last with the USB disk `readFrom` (nil for none), is not what a read would give with
    /// the disk known now (`usb`): its rows of a disk that has left the slot are not to be written to and go with a
    /// read, and a disk that has turned up, or that the last read could not read, comes in with one. Nothing
    /// changes in a home with no USB disk, where both sides are none.
    func isOutdated(readFrom: RecorderDisk?, usb: RecorderDisk?) -> Bool {
        guard let readFrom else {
            // None read: a disk there is to be, and rows held of one that has gone since are to go.
            return usb?.takesRecordings == true || contains { $0.readFrom != nil }
        }
        return !readFrom.isStill(usb)
    }
}
