import Foundation
@testable import RecorderKit

/// Answers canned responses and records what was sent, so request shapes and the no-overlap rule can be
/// checked without a recorder. `maxConcurrent` is what proves the serialization: the recorder answers 503 to
/// concurrent requests, so it must never exceed one.
actor StubTransport: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    private(set) var maxConcurrent = 0
    private var active = 0
    private let handler: @Sendable (HTTPRequest, Int) async throws -> HTTPResponse

    init(handler: @escaping @Sendable (HTTPRequest, Int) async throws -> HTTPResponse) {
        self.handler = handler
    }

    /// Shorthand for a stub that answers the same thing every time.
    init(always response: HTTPResponse) {
        self.handler = { _, _ in response }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let index = requests.count
        requests.append(request)
        active += 1
        maxConcurrent = max(maxConcurrent, active)
        defer { active -= 1 }
        return try await handler(request, index)
    }

    var bodies: [String] { requests.map { String(decoding: $0.body ?? Data(), as: UTF8.self) } }
}

enum Stub {
    /// A SOAP answer of the shape the recorder gives, with the inner payload escaped as it arrives in practice.
    static func soap(_ action: String, result: String? = nil, totalMatches: Int? = nil,
                     extra: String = "") -> HTTPResponse {
        var inner = ""
        if let result { inner += "<Result>\(Soap.escape(result))</Result>" }
        if let totalMatches { inner += "<TotalMatches>\(totalMatches)</TotalMatches>" }
        inner += extra
        let body = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\">"
            + "<s:Body><u:\(action)Response xmlns:u=\"\(Upnp.xsrsService)\">\(inner)"
            + "</u:\(action)Response></s:Body></s:Envelope>"
        return HTTPResponse(statusCode: 200, body: Data(body.utf8))
    }

    /// What a rejected request looks like: HTTP 500 carrying a UPnP error code.
    static func fault(_ code: String) -> HTTPResponse {
        let body = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body>"
            + "<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>"
            + "<UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>\(code)</errorCode></UPnPError>"
            + "</detail></s:Fault></s:Body></s:Envelope>"
        return HTTPResponse(statusCode: 500, body: Data(body.utf8))
    }

    /// A DIDL-Lite fragment: containers to walk into, and optionally an item whose `<res>` names the port the
    /// guide files are served from.
    static func didl(containers: [String] = [], resourcePort: Int? = nil) -> String {
        var xml = "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\">"
        for id in containers { xml += "<container id=\"\(id)\" parentID=\"0\"><dc:title>x</dc:title></container>" }
        if let resourcePort {
            xml += "<item id=\"V_1\" parentID=\"0\"><res protocolInfo=\"http-get\">"
                + "http://192.0.2.10:\(resourcePort)/V_1.m2ts</res></item>"
        }
        return xml + "</DIDL-Lite>"
    }

    static let host = "192.0.2.10"
}
