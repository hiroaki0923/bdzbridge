import Foundation

extension RecordedTitle {
    /// A row of a television's list (`ScalarClient.recordings`), by what was measured of version 1.5: the uri, its
    /// name for the recording, as the id; the start with its offset written `+0900`; the length in `duration` and
    /// the size in `sizeMB`, since `fileSizeByte` is -1 on a large one; and `isProtected`, `isAlreadyPlayed` and
    /// `recordingInfo.isRecording` as the strings `true` and `false`. There is no `eventId`, no service id and no
    /// mode, and a resume point has not been seen.
    ///
    /// A row being recorded says nought for its length and its size, which do not grow until it ends: its size is
    /// none, and its length is not to be said (`lengthKnown`). The text may be absent, or there and empty, which is
    /// none either way. The genre is the first of `broadcastGenreInfo`, taken to be the recorder's code for one,
    /// level 1 times sixteen and level 2: which codes a television writes there has not been looked at beside its
    /// own screen, and what is no such code is no genre.
    ///
    /// Nil without a uri, or a start that reads as a time, so that such a row is left out, as a recorder's is,
    /// rather than the whole list refused for it.
    init?(televisionRow row: [String: ScalarValue]) {
        guard let uri = row["uri"]?.text, !uri.isEmpty,
              let start = row["startDateTime"]?.text.flatMap(RecorderTime.parse) else { return nil }
        func flag(_ value: ScalarValue?) -> Bool { value?.text == "true" }
        func said(_ value: ScalarValue?) -> String? { value?.text.flatMap { $0.isEmpty ? nil : $0 } }
        let recording = flag(row["recordingInfo"]?["isRecording"])
        var genre: Int?
        if case .list(let genres)? = row["broadcastGenreInfo"], let code = genres.first?["genreId"]?.whole,
           (0...255).contains(code) {
            genre = code
        }
        self.init(id: uri, title: row["title"]?.text ?? "", start: start,
                  durationSec: row["duration"]?["durationSec"]?.whole ?? 0, broadcastingType: 0, serviceID: 0,
                  qualityCode: 0, protected: flag(row["isProtected"]), isNew: !flag(row["isAlreadyPlayed"]),
                  recording: recording, destination: TVDriver.recordsTo,
                  sizeMB: recording ? nil : row["sizeMB"]?.whole, genreCode: genre, device: .tv,
                  channelName: said(row["channelName"]), summary: said(row["description"]?["summary"]),
                  details: said(row["description"]?["detail"]))
    }
}

extension TVDriver {
    /// What a television's recordings are filtered by, beside the recorder's disks: it has the one disk.
    public nonisolated static let recordsTo = "TV"
}
