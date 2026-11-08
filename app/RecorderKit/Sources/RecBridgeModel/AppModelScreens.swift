import Foundation
import RecorderKit

/// Rules the screens draw by, kept with the model so that its tests hold them: the screens are the app's, which
/// the tests cannot reach.
extension AppModel {
    /// One row of the recorder's free space.
    public struct StorageRow: Equatable, Sendable {
        public var label: String
        public var value: String
    }

    /// The recorder's free space as the settings list it. With its own disk alone, the one row it has always
    /// had. Once a USB disk is known, a row to a disk, each under the recorder's word for it and in the words the
    /// television's USB disk is described in, and the internal disk's only when it said how full it is, as before.
    public static func storageRows(storage: (free: Int, total: Int)?, usb: RecorderDisk?) -> [StorageRow] {
        var rows: [StorageRow] = []
        if let storage {
            rows.append(usb == nil
                ? StorageRow(label: "残り容量",
                             value: "\(Format.gigabytes(storage.free, on: .recorder))"
                                 + " / \(Format.gigabytes(storage.total, on: .recorder))")
                : StorageRow(label: RecorderDisk.label(RecorderDisk.internalID, named: nil),
                             value: Format.storage(mounted: true, freeBytes: storage.free, totalBytes: storage.total,
                                                   on: .recorder)))
        }
        if let usb {
            rows.append(StorageRow(label: RecorderDisk.label(usb.destination, named: usb.name),
                                   value: Format.storage(mounted: usb.mounted, freeBytes: usb.freeBytes,
                                                         totalBytes: usb.totalBytes, on: .recorder)))
        }
        return rows
    }

    /// What is about to go, and how much of the disk it gives back. Said in full because there is no undo.
    public static func deleteMessage(_ title: RecordedTitle) -> String {
        var lines = [title.title, Format.dateTime.string(from: title.start)]
        if let size = Format.size(of: title) { lines.append(size) }
        return lines.joined(separator: "\n") + "\n" + [title].deletedForGood.asABody
    }

    /// The recordings ticked, of those the sheet lists. By key (`RecordedTitle.listKey`): the list can be read
    /// again under an open sheet, and a tick on a disk since gone says nothing of a row of the next one.
    public static func chosenTitles(among members: [RecordedTitle], _ selected: Set<String>) -> [RecordedTitle] {
        members.filter { selected.contains($0.listKey) }
    }
}
