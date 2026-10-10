import Foundation

/// What a run over many recordings does to each of them: deletes it, protects it or takes its protection off,
/// or, for the scan for duplicates, asks the recorder what it is about, which changes nothing.
public enum RunKind: Sendable, Equatable {
    case delete
    case protecting(Bool)
    case scanning
}

/// The recorder's work over many recordings, one request at a time because that is all the recorder will take:
/// the bulk delete, the bulk protect and the scan for duplicates. What is here is the recorder's side of a run,
/// beginning with its words; the loop around the recordings, its job with the progress and the stop button, the
/// wait while the app is away and the lists are the app's.
extension RecorderDriver {
    // MARK: - a run's words

    /// What a run of this kind does, as its job says it while it runs (「削除中 3 / 12」).
    public nonisolated static func verb(of kind: RunKind) -> String {
        switch kind {
        case .delete: "削除"
        case .protecting(true): "保護"
        case .protecting(false): "保護解除"
        case .scanning: "重複の検出"
        }
    }

    /// What to tell the reader once a run has stopped, in the shape the web app settled on: how many recordings
    /// it changed -- a scan, how many it looked at (`done`) -- whether it came to its end, was stopped by 中止
    /// (`cancelled`) or lost the recorder (`lost`), which is said whether or not 中止 was tapped as well, and how
    /// many it passed over.
    public nonisolated static func outcome(of kind: RunKind, done: Int, changed: Int, passedOver: Int,
                                           cancelled: Bool, lost: Bool) -> String {
        if case .scanning = kind {
            let head = lost ? "\(done) 件まで調べたところで、レコーダーの応答がなくなったため中止しました"
                : cancelled ? "\(done) 件まで調べて中止しました" : "\(done) 件の確認が完了しました"
            return passedOver == 0 ? head : head + "（\(passedOver) 件は番組内容を取得できず、比べていません）"
        }
        let verb = verb(of: kind)
        let head = lost ? "\(changed) 件を\(verb)したところで、レコーダーの応答がなくなったため中止しました"
            : cancelled ? "\(changed) 件を\(verb)したところで中止しました" : "\(changed) 件を\(verb)しました"
        return passedOver == 0 ? head : head + "（\(passedOver) 件はスキップ）"
    }

    /// Why a recording was passed over that the list no longer holds by the time the run comes to it.
    public nonisolated static let notInTheList = "一覧に見つかりません"
}
