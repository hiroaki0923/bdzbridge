import Foundation

/// An invented Sony BRAVIA: it answers the methods the app uses, in the shapes a real one gives them, and remembers
/// what it was told -- the clients registered with it and the cookies it gave out. For the tests of the package and of
/// the app, and for the demo, as `DemoRecorder` is for the recorder. Every value in it is invented.
///
/// Each request is put down in `calls` as its method and whether a cookie or a PIN came with it, which is what the
/// tests read: what was asked, never the cookie itself.
public actor DemoTV: HTTPTransport {
    /// Sony's OUI and the rest zeroed, as everywhere in this repository, with a last digit of its own.
    public static let mac = "f8:4e:17:00:00:0a"
    public static let model = "KJ-SAMPLE"
    public static let pin = "1234"

    /// `standby` or `active`. It shows its PIN, and so can be registered by one, only when active.
    public var power: String
    public private(set) var mac: String
    private var silent = false
    private var cookies: Set<String> = []
    private var registered: Set<String> = []
    private var issued = 0
    public private(set) var calls: [String] = []

    public init(power: String = "standby", mac: String = DemoTV.mac) {
        self.power = power
        self.mac = mac
    }

    /// Says nothing from now on, as a television does that has left the network, or answers again.
    public func goSilent(_ value: Bool = true) { silent = value }
    /// Answers as another television would, with a MAC of its own.
    public func becomeAnother(mac: String) { self.mac = mac }

    /// A client registered with its PIN before, holding `cookie`.
    public func knows(_ clientID: String, cookie: String) {
        registered.insert(clientID)
        cookies.insert(cookie)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let object = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any] ?? [:]
        let method = object["method"] as? String ?? ""
        let id = object["id"] as? Int ?? 0
        let cookie = request.headers["Cookie"].map { String($0.dropFirst("auth=".count)) }
        calls.append("\(method) cookie=\(cookie == nil ? "no" : "yes") pin=\(request.headers["Authorization"] == nil ? "no" : "yes")")
        if silent { throw RecorderError.transport("The request timed out.") }
        switch method {
        case "getPowerStatus":
            return ok(#"[{"status":"\#(power)"}]"#, id)
        case "getInterfaceInformation":
            return ok(#"[{"productCategory":"tv","productName":"BRAVIA","modelName":"\#(Self.model)","serverName":"","interfaceVersion":"5.7.0"}]"#, id)
        case "getSystemSupportedFunction":
            return ok(#"[[{"option":"WOL","value":"\#(mac)"}]]"#, id)
        case "getStorageList":
            guard let cookie, cookies.contains(cookie) else { return HTTPResponse(statusCode: 403) }
            return ok(#"[[{"uri":"usb:recStorage","mounted":"mounted","wholeCapacityMB":1000,"freeCapacityMB":400}]]"#, id)
        case "actRegister":
            return register(object, request, id)
        default:
            return HTTPResponse(statusCode: 200, body: Data(#"{"error":[12,"\#(method)"],"id":\#(id)}"#.utf8))
        }
    }

    /// A client it lists gets a new cookie, in standby as well, and the ones given before stay good. One it does
    /// not list is answered 401 while the display is on, as the real one answers while it shows its PIN, and is
    /// registered by the request that carries the PIN. In standby nothing is shown: such a client is turned down
    /// with error 40005 and no cookie, as the real one turns down a request with nothing on it -- and, it is
    /// taken, one with a PIN, which has not been tried.
    private func register(_ object: [String: Any], _ request: HTTPRequest, _ id: Int) -> HTTPResponse {
        let clientID = ((object["params"] as? [Any])?.first as? [String: Any])?["clientid"] as? String ?? ""
        if !registered.contains(clientID) {
            guard power == "active" else {
                return HTTPResponse(statusCode: 200, body: Data(#"{"error":[40005,"display off"],"id":\#(id)}"#.utf8))
            }
            guard request.headers["Authorization"] == "Basic " + Data(":\(Self.pin)".utf8).base64EncodedString() else {
                return HTTPResponse(statusCode: 401)
            }
            registered.insert(clientID)
        }
        issued += 1
        let value = "invented-\(issued)"
        cookies.insert(value)
        return HTTPResponse(statusCode: 200, body: Data(#"{"result":[],"id":\#(id)}"#.utf8),
                            headers: ["Set-Cookie": "auth=\(value); Path=/sony/; Max-Age=1209600"])
    }

    private func ok(_ result: String, _ id: Int) -> HTTPResponse {
        HTTPResponse(statusCode: 200, body: Data(#"{"result":\#(result),"id":\#(id)}"#.utf8))
    }
}
