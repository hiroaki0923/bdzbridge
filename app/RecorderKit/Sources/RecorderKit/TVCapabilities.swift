import Foundation

/// What a television says it speaks, for the services the app sends to: the versions of each, and its methods with
/// their versions. A television the app does not work with as it is -- an older one answers error 12 to a version
/// it does not have -- is understood from this, which the reader can copy from the settings and send on. Asked
/// with no registration, and nothing is changed: `getInterfaceInformation`, `getPowerStatus`, `getRecordingStatus`,
/// `getSystemSupportedFunction`, and `getVersions` and `getMethodTypes` of each service.
///
/// A list of methods does not say whether a version answers, nor what its rows are made of -- a television was seen
/// to list `getScheduleList` 1.0 and answer it with error 7 -- and support for a model is built on both. So where
/// the app holds a registration for the television, the reads the app makes are tried with it too, in each version
/// the app may send them in (`Trial`). Reads alone: nothing is made, changed or lit, and nothing of what the rows
/// say is in the report, only what they are made of.
public struct TVCapabilities: Sendable, Equatable {
    public struct Method: Sendable, Equatable {
        public var name: String
        public var version: String
        /// The parameters' and the results' types, as the television writes them.
        public var parameters: [String]
        public var results: [String]
    }

    public struct Service: Sendable, Equatable {
        public var name: String
        public var versions: [String]
        public var methods: [Method]
        /// Why the service could not be read, nil when it was.
        public var failure: String?
    }

    /// One read the app makes, tried in one version, and what came of it, by kinds and counts alone: no title, no
    /// station, no uri, no time, nothing of what is recorded or reserved.
    public struct Trial: Sendable, Equatable {
        public var label: String
        /// Why nothing was read, nil when something was.
        public var failure: String?
        /// The rows the answer held, and how many of them the app's own reader takes.
        public var rows = 0
        public var taken = 0
        /// Each field of the rows with the type its value came as, nested ones by their path (`TVCapabilities.fields`).
        public var fields: [String] = []
        /// The forms of the start and of the uri, and the values of the fields that take only a few.
        public var forms: [String] = []
    }

    public var model: String?
    public var interfaceVersion: String?
    /// What `getPowerStatus` and `getRecordingStatus` said, or why they could not be read.
    public var power: String?
    public var recordingStatus: String?
    /// Whether `getSystemSupportedFunction` gives a MAC to wake it by, which the app also knows it again by: said
    /// as there or not, never the MAC.
    public var wakeOnLAN: String?
    public var services: [Service]
    /// The reads tried with the registration, nil where the app holds none for the television.
    public var trials: [Trial]?

    /// The services asked of: those the app sends to.
    public static let servicesAsked = ["system", "recording", "avContent", "accessControl"]

    /// The methods the app sends, whose types the report spells out; the others are listed by name and version.
    public static let methodsSent: Set<String> = [
        "getPowerStatus", "getInterfaceInformation", "getSystemSupportedFunction", "getStorageList",
        "getScheduleList", "addSchedule", "deleteSchedule", "getConflictScheduleList", "getRecordingStatus",
        "getContentList", "getContentCount", "setDeleteProtection", "deleteContent", "actRegister",
    ]

    /// The fields whose values are said, distinct, in a trial: those that take only a few words.
    static let fieldsOfFewValues = ["type", "repeatType", "overlapStatus", "recordingStatus", "quality", "mounted"]

    /// The whole of it as text, to be read and copied: the app's version first (`app`), then the model, the power
    /// and the recording status, then each service with its versions, the methods the app sends with their types,
    /// and the rest by name and version, and last the reads tried.
    public func report(app: String) -> String {
        var lines = ["RecBridge \(app)", "機種: \(model ?? "読めませんでした")" + (interfaceVersion.map { "（\($0)）" } ?? ""),
                     "電源: \(power ?? "読めませんでした")", "録画の状態: \(recordingStatus ?? "読めませんでした")",
                     "Wake-on-LAN の MAC: \(wakeOnLAN ?? "読めませんでした")"]
        for service in services {
            lines.append("")
            if let failure = service.failure {
                lines.append("\(service.name): \(failure)")
                continue
            }
            lines.append("\(service.name) \(service.versions.joined(separator: " "))")
            let sent = service.methods.filter { Self.methodsSent.contains($0.name) }
            for method in sent {
                lines.append("  \(method.name) \(method.version) (\(method.parameters.joined(separator: ", ")))"
                             + " → (\(method.results.joined(separator: ", ")))")
            }
            let others = service.methods.filter { !Self.methodsSent.contains($0.name) }
                .map { "\($0.name) \($0.version)" }
            if !others.isEmpty { lines.append("  ほか: " + others.joined(separator: ", ")) }
        }
        lines.append("")
        guard let trials else {
            lines.append("読み取りの試し: このテレビの登録が無いため、していません")
            return lines.joined(separator: "\n")
        }
        lines.append("読み取りの試し（登録を使い、読むだけです。番組名や局名は含みません）")
        for trial in trials {
            if let failure = trial.failure {
                lines.append("\(trial.label): \(failure)")
                continue
            }
            lines.append("\(trial.label): \(trial.rows) 行、アプリが読めたのは \(trial.taken) 行")
            if !trial.fields.isEmpty { lines.append("  項目: " + trial.fields.joined(separator: ", ")) }
            lines += trial.forms.map { "  " + $0 }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - what the rows are made of, and nothing of what they say

extension TVCapabilities {
    /// A value of a field that takes only a few, as it came where it is a short word, `…` otherwise: so that
    /// nothing a person wrote is ever in the report.
    static func word(_ value: String) -> String {
        guard !value.isEmpty else { return "(空)" }
        let plain = value.count <= 24 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) }
        return plain ? value : "…"
    }

    /// An error's own message where it is a short phrase of plain letters, as `Illegal State` is; `…` otherwise.
    static func phrase(_ message: String) -> String {
        let plain = message.count <= 40 && message.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || " _-.:".contains($0)) }
        return plain ? message : "…"
    }

    /// The form of a time as it was written, each digit a 9: `2026-11-01T21:00:00+0900` is
    /// `9999-99-99T99:99:99+9999`.
    static func timeForm(_ text: String) -> String {
        hidden(String(text.prefix(40).map { $0.isNumber ? "9" : ($0.isASCII ? $0 : "…") }))
    }

    /// Each run of what was not to be shown as one `…`.
    private static func hidden(_ text: String) -> String {
        text.replacingOccurrences(of: "…+", with: "…", options: .regularExpression)
    }

    /// The form of a uri, with nothing of what it names: the scheme, the path with each digit a 9, and the names
    /// of its parameters without their values -- a station's is `tv:isdbt?trip&srvName`, never the station.
    static func uriForm(_ uri: String) -> String {
        let parts = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let head = String(parts.first ?? "").prefix(40).map { character -> Character in
            if character.isNumber { return "9" }
            return character.isASCII && (character.isLetter || ":/._-".contains(character)) ? character : "…"
        }
        guard parts.count == 2 else { return hidden(String(head)) }
        let names = parts[1].split(separator: "&").map { word(String($0.split(separator: "=").first ?? "")) }
        return hidden(String(head)) + "?" + names.joined(separator: "&")
    }

    /// Each field of `rows` with the type its value came as, nested ones by their path -- `duration.durationSec:int`,
    /// `broadcastGenreInfo[].genreId:string` -- in the order of their names. A field not every row has says how many
    /// do, and one that came as more than one type says each.
    static func fields(of rows: [[String: ScalarValue]]) -> [String] {
        var seen: [String: (types: Set<String>, rows: Int)] = [:]
        for row in rows {
            var inRow: [String: Set<String>] = [:]
            collect(row, under: "", into: &inRow)
            for (path, types) in inRow {
                seen[path, default: ([], 0)].types.formUnion(types)
                seen[path, default: ([], 0)].rows += 1
            }
        }
        return seen.keys.sorted().compactMap { path in
            guard let (types, count) = seen[path] else { return nil }
            return "\(path):\(types.sorted().joined(separator: "|"))" + (count < rows.count ? " (\(count)/\(rows.count))" : "")
        }
    }

    private static func collect(_ object: [String: ScalarValue], under prefix: String,
                                into paths: inout [String: Set<String>]) {
        for (key, value) in object {
            let path = prefix + word(key)
            switch value {
            case .object(let inner) where inner.isEmpty:
                paths[path, default: []].insert("{}")
            case .object(let inner):
                collect(inner, under: path + ".", into: &paths)
            case .list(let items) where items.isEmpty:
                paths[path, default: []].insert("[]")
            case .list(let items):
                for item in items {
                    if case .object(let inner) = item {
                        collect(inner, under: path + "[].", into: &paths)
                    } else {
                        paths[path + "[]", default: []].insert(typeName(of: item))
                    }
                }
            default:
                paths[path, default: []].insert(typeName(of: value))
            }
        }
    }

    private static func typeName(of value: ScalarValue) -> String {
        switch value {
        case .string: "string"
        case .int: "int"
        case .double: "double"
        case .bool: "bool"
        case .list: "list"
        case .object: "object"
        case .null: "null"
        }
    }

    /// What else is said of `rows`: each form of their start, with whether the app reads it, each form of their
    /// uri, and the values of the fields that take only a few (`fieldsOfFewValues`). Five of each at most.
    static func forms(of rows: [[String: ScalarValue]]) -> [String] {
        func distinct(_ values: [String]) -> [String] { Array(Set(values)).sorted().prefix(5).map { $0 } }
        let starts = rows.compactMap { $0["startDateTime"]?.text }
        var forms = distinct(starts.map { start in
            timeForm(start) + (RecorderTime.parse(start) == nil ? "（アプリが読めない）" : "（アプリが読める）")
        }).map { "startDateTime: " + $0 }
        let uris = distinct(rows.compactMap { $0["uri"]?.text }.map(uriForm))
        if !uris.isEmpty { forms.append("uri: " + uris.joined(separator: ", ")) }
        for field in fieldsOfFewValues {
            let values = distinct(rows.compactMap { $0[field]?.text }.map(word))
            if !values.isEmpty { forms.append("\(field): " + values.joined(separator: ", ")) }
        }
        return forms
    }

    /// A failure said by its kind, the television's own message where it is a plain phrase.
    static func failure(_ error: any Error) -> String {
        switch error {
        case ScalarError.rpc(_, _, let code, let message):
            "エラー \(code)" + (message.isEmpty ? "" : "（\(phrase(message))）")
        case ScalarError.http(let status, _): "HTTP \(status)"
        case ScalarError.unreadable: "応答を読み取れませんでした"
        case ScalarError.notRegistered: "登録がありません"
        case let error as any DeviceError: error.explanation
        default: String(describing: error)
        }
    }

    /// The shape of an answer that is not a list of rows, by types and names alone.
    static func shape(of value: ScalarValue) -> String {
        switch value {
        case .list(let items): "[" + (items.first.map(shape) ?? "") + "]"
        case .object(let fields): "{" + fields.keys.sorted().map(word).joined(separator: ",") + "}"
        default: typeName(of: value)
        }
    }
}

extension ScalarClient {
    /// What the television says it speaks (`TVCapabilities`), each service read on its own: one that cannot be
    /// read says why, and the rest are still read. Where the app holds a registration for it, the reads the app
    /// makes are tried as well (`trials`).
    public func capabilities() async -> TVCapabilities {
        let interface = try? await interface()
        let power: String
        do { power = TVCapabilities.word(try await powerStatus()) } catch { power = Self.said(error) }
        let recording: String
        do { recording = TVCapabilities.word(try await recordingStatus()) } catch { recording = Self.said(error) }
        let wake: String
        do { wake = try await wakeOnLANAddress() == nil ? "なし" : "あり" } catch { wake = Self.said(error) }
        var services: [TVCapabilities.Service] = []
        for name in TVCapabilities.servicesAsked {
            do {
                let versions = try await whole(name, "getVersions", version: "1.0")["result"]
                    .flatMap { ($0 as? [Any])?.first as? [String] } ?? []
                let listed = try await whole(name, "getMethodTypes", version: "1.0", params: [""])
                let rows = (listed["results"] ?? listed["result"]) as? [Any] ?? []
                let methods = rows.compactMap { row -> TVCapabilities.Method? in
                    guard let fields = row as? [Any], fields.count >= 4, let name = fields[0] as? String,
                          let version = fields[3] as? String else { return nil }
                    return TVCapabilities.Method(name: name, version: version,
                                                 parameters: fields[1] as? [String] ?? [],
                                                 results: fields[2] as? [String] ?? [])
                }
                services.append(TVCapabilities.Service(name: name, versions: versions, methods: methods))
            } catch {
                services.append(TVCapabilities.Service(name: name, versions: [], methods: [],
                                                       failure: Self.said(error)))
            }
        }
        return TVCapabilities(model: interface?.modelName, interfaceVersion: interface?.interfaceVersion,
                              power: power, recordingStatus: recording, wakeOnLAN: wake, services: services,
                              trials: holdsARegistration ? await trials() : nil)
    }

    /// The reads the app makes, each in every version it may send it in, with the registration, the first page of
    /// each: the disk; the reservations in 1.1 and 1.0; the recordings in 1.5, 1.2 and 1.0; the stations of
    /// terrestrial broadcasting, BS and CS; and the question a reservation is checked with before it is made, asked
    /// of a reservation as the app writes one -- on the first station read, tomorrow at this hour -- which says
    /// whether the television takes what the app sends without anything being made. A read the television does not
    /// answer at all ends them: the rest would only wait as long again.
    func trials() async -> [TVCapabilities.Trial] {
        let disk = ScalarClient.recordingsSource
        var trials: [TVCapabilities.Trial] = []
        guard await tried("getStorageList 1.1", "system", "getStorageList", "1.1", ["uri": disk],
                          into: &trials, takes: { $0["mounted"] is String }) != nil else { return trials }
        for version in ["1.1", "1.0"] {
            guard await tried("getScheduleList \(version)", "recording", "getScheduleList", version,
                              ["stIdx": 0, "cnt": 130], into: &trials, takes: { TVScheduleRow($0) != nil }) != nil else { return trials }
        }
        for version in ["1.5", "1.2", "1.0"] {
            guard await tried("getContentList \(version)（録画）", "avContent", "getContentList", version,
                              [version == "1.5" ? "uri" : "source": disk, "stIdx": 0, "cnt": Self.recordingsToAPage],
                              into: &trials, takes: { row in
                                  guard case .object(let fields)? = ScalarValue(json: row) else { return false }
                                  return RecordedTitle(televisionRow: fields) != nil
                              }) != nil else { return trials }
        }
        var station: TVStation?
        for (code, said) in [("td", "地上デジタル"), ("bs", "BS"), ("cs", "CS")] {
            guard let type = Codes.broadcasting[code], let source = TVStation.source(of: type) else { continue }
            guard let rows = await tried("getContentList 1.0（\(said)の局）", "avContent", "getContentList", "1.0",
                                         ["source": source, "stIdx": 0, "cnt": Self.stationsToAPage],
                                         into: &trials, takes: { TVStation($0, broadcastingType: type) != nil }) else { return trials }
            station = station ?? rows.lazy.compactMap { TVStation($0, broadcastingType: type) }.first
        }
        let label = "getConflictScheduleList 1.0（アプリが送る予約の形で）"
        let hour = (Date().timeIntervalSince1970 / 3600).rounded(.down) * 3600
        guard let station,
              let body = TVReservationBody(ReservationRequest(title: "RecBridge", start: Date(timeIntervalSince1970: hour + 86_400),
                                                              durationSec: 1800, repeatCode: "1",
                                                              broadcastingType: station.broadcastingType,
                                                              serviceID: station.serviceID, qualityCode: 0,
                                                              // Not in the question: a body is made with one.
                                                              eventID: 0),
                                           on: station) else {
            trials.append(TVCapabilities.Trial(label: label, failure: "局が読めなかったため、していません"))
            return trials
        }
        var trial = TVCapabilities.Trial(label: label)
        do {
            let named = try await wouldPushOut(body)
            (trial.rows, trial.taken) = (named.count, named.count)
        } catch {
            trial.failure = TVCapabilities.failure(error)
        }
        trials.append(trial)
        return trials
    }

    /// A trial put in `trials`, and a note that the rest were not tried where the television did not answer at all:
    /// the rows, empty where there were none, or nil for that silence.
    private func tried(_ label: String, _ service: String, _ method: String, _ version: String,
                       _ params: [String: Any], into trials: inout [TVCapabilities.Trial],
                       takes: ([String: Any]) -> Bool) async -> [[String: Any]]? {
        let (trial, rows, answered) = await self.trial(label, service, method, version, params, takes: takes)
        trials.append(trial)
        if !answered {
            trials.append(TVCapabilities.Trial(label: "ここで止めました", failure: "テレビが答えないため"))
        }
        return answered ? rows ?? [] : nil
    }

    /// One read with the registration, and what of its rows goes in the report; with the rows, for whoever reads
    /// on from them, and whether the television answered at all.
    private func trial(_ label: String, _ service: String, _ method: String, _ version: String,
                       _ params: [String: Any],
                       takes: ([String: Any]) -> Bool) async -> (TVCapabilities.Trial, [[String: Any]]?, Bool) {
        var trial = TVCapabilities.Trial(label: label)
        let result: Any
        do {
            result = try await registeredResult(service, method, version: version, params: [params])
        } catch {
            trial.failure = TVCapabilities.failure(error)
            return (trial, nil, (error as? any DeviceError)?.failure != .silent)
        }
        guard let rows = (result as? [Any])?.first as? [Any] else {
            trial.failure = "行の一覧ではない応答でした: " + (ScalarValue(json: result).map(TVCapabilities.shape) ?? "読めない値")
            return (trial, nil, true)
        }
        let objects = rows.compactMap { $0 as? [String: Any] }
        let values = objects.compactMap { row -> [String: ScalarValue]? in
            guard case .object(let fields)? = ScalarValue(json: row) else { return nil }
            return fields
        }
        trial.rows = rows.count
        trial.taken = objects.filter(takes).count
        trial.fields = TVCapabilities.fields(of: values)
        trial.forms = TVCapabilities.forms(of: values)
        return (trial, objects, true)
    }

    private static func said(_ error: any Error) -> String {
        switch error {
        case ScalarError.http(let status, _): "読めませんでした（HTTP \(status)）"
        case ScalarError.rpc(_, _, let code, _): "読めませんでした（エラー \(code)）"
        case let error as any DeviceError: error.explanation
        default: String(describing: error)
        }
    }
}
