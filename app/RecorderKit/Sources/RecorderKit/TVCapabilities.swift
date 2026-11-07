import Foundation

/// What a television says it speaks, for the services the app sends to: the versions of each, and its methods with
/// their versions. A television the app does not work with as it is -- an older one answers error 12 to a version
/// it does not have -- is understood from this, which the reader can copy from the settings and send on. Asked
/// with no registration, and nothing is changed: `getInterfaceInformation`, and `getVersions` and
/// `getMethodTypes` of each service.
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

    public var model: String?
    public var interfaceVersion: String?
    public var services: [Service]

    /// The services asked of: those the app sends to.
    public static let servicesAsked = ["system", "recording", "avContent", "accessControl"]

    /// The methods the app sends, whose types the report spells out; the others are listed by name and version.
    public static let methodsSent: Set<String> = [
        "getPowerStatus", "getInterfaceInformation", "getSystemSupportedFunction", "getStorageList",
        "getScheduleList", "addSchedule", "deleteSchedule", "getConflictScheduleList", "getRecordingStatus",
        "getContentList", "getContentCount", "setDeleteProtection", "deleteContent", "actRegister",
    ]

    /// The whole of it as text, to be read and copied: the app's version first (`app`), then the model, then each
    /// service with its versions, the methods the app sends with their types, and the rest by name and version.
    public func report(app: String) -> String {
        var lines = ["RecBridge \(app)", "機種: \(model ?? "読めませんでした")" + (interfaceVersion.map { "（\($0)）" } ?? "")]
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
        return lines.joined(separator: "\n")
    }
}

extension ScalarClient {
    /// What the television says it speaks (`TVCapabilities`), each service read on its own: one that cannot be
    /// read says why, and the rest are still read.
    public func capabilities() async -> TVCapabilities {
        let interface = try? await interface()
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
                              services: services)
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
