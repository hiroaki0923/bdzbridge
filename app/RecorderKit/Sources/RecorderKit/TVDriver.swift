import Foundation
import Observation

/// What a television said of itself, for the screens: kept by its driver rather than in `SessionState`, which
/// holds what every device has. Nil and false until the television has said.
@MainActor
@Observable
public final class TVFacts {
    /// The model, as `getInterfaceInformation` gives it.
    public internal(set) var model: String?
    /// Set when the television answers but has no working registration for the app: a PIN is wanted.
    public internal(set) var needsPairing = false
    /// The USB disk it records to, as last read.
    public internal(set) var storage: TVStorage?

    public init() {}
}

/// What is particular to a Sony BRAVIA in a link. It is asked whether it is on (`getPowerStatus`, which it
/// answers in standby) and never woken: nothing reaches a television asleep without lighting it, and the app
/// does not light it unasked. It is told from any other by the MAC it wakes on. An attach reads that, its model,
/// and its USB disk -- the read that needs a registration, so the one that says whether there is one -- and
/// renews the cookie when it is past half its life.
@MainActor
public final class TVDriver: LinkDriver {
    public let facts = TVFacts()
    private let credentials: any TVCredentialStore
    /// What the television lists the app as, among the devices registered with it.
    private let nickname: String
    /// Whether the app is in front, the only place a renewal is asked for: what a television that no longer
    /// lists the app does with one is not known, and a screen lit by it should have the reader there to see why.
    private let inFront: @MainActor () -> Bool

    public init(credentials: any TVCredentialStore, nickname: String, inFront: @escaping @MainActor () -> Bool) {
        self.credentials = credentials
        self.nickname = nickname
        self.inFront = inFront
    }

    public var probeTimeout: TimeInterval { 5 }

    public var noAnswerLine: String { ScalarError.transport("no answer").explanation }

    public func makeClient(for link: DeviceLink) -> any LinkClient {
        ScalarClient(host: link.host, transport: link.environment.transport(link.host), credentials: credentials)
    }

    public func canWake(_ link: DeviceLink) -> Bool { false }

    public func sendPacket(_ link: DeviceLink) {}

    // MARK: - attaching

    /// The first ask needs no registration: the MAC that says which television this is. Then the model, which is
    /// only shown, and the USB disk, which needs the registration: a television that refuses it answered, so it
    /// is there and is not given up on, but nothing can be asked of it until it is registered again. What waits
    /// is sent last, as a recorder's attach does.
    public func attach(_ link: DeviceLink, client: any LinkClient, what: String? = "接続中",
                       timeout: TimeInterval? = nil, quiet: Bool = false) async -> Bool {
        guard let client = client as? ScalarClient else { return false }
        let owner = link.owner
        // A line that says which device, beside the recorder's own 接続中 when both connect at once.
        var activity: Activities.Token?
        if what != nil { activity = owner?.beginActivity(Self.connectingLine) }
        defer { if let activity { owner?.endActivity(activity) } }
        do {
            let identity = (try await client.wakeOnLANAddress(timeout: timeout)).flatMap(WakeOnLan.normalise) ?? ""
            guard link.session.recognises(identity: identity) != .another else {
                // Its cookie would not be good here, and what waits was made for the television registered.
                link.session.strangerAnswered()
                owner?.problem = Self.anotherAnswered
                return false
            }
            link.session.identified(as: identity)
            owner?.keepAddress(link.host)
            if !identity.isEmpty { owner?.keepMAC(identity) }
            if let model = try await RecorderError.silenceOnly({ try await client.interface().modelName }),
               !model.isEmpty {
                facts.model = model
            }
            facts.storage = try await client.storage()
            facts.needsPairing = false
            if inFront(), credentials.load()?.renewalDue(now: Date()) == true {
                // A renewal that fails costs nothing: the cookie in hand is still good.
                _ = try await RecorderError.silenceOnly { try await client.renew(nickname: nickname) }
            }
            link.session.answered()
            owner?.problem = nil
            await owner?.sendWhatWaits()
            guard !link.session.unreachable else { return false }
            link.session.attached()
            return true
        } catch {
            let deviceError = error as? any DeviceError
            if deviceError?.failure == .needsPairing { facts.needsPairing = true }
            link.session.attachFailed(deviceError?.failure)
            if !quiet || !link.session.unreachable {
                owner?.problem = deviceError?.explanation ?? String(describing: error)
            }
            return false
        }
    }

    public static let connectingLine = "テレビに接続中"

    /// Said when the device at the television's address is another one.
    public static let anotherAnswered = "登録したテレビとは別の機器が応答しました。設定の「テレビ」から追加し直してください。"

    /// Never: see the type's description.
    public func wakeAndAttach(_ link: DeviceLink, client: any LinkClient) async -> Bool { false }

    /// Not looked for at another address yet.
    public func findElsewhere(_ link: DeviceLink) async -> DeviceFailure? { .silent }

    // MARK: - the check before an operation

    public func check(_ link: DeviceLink, client: any LinkClient) async -> (failure: DeviceFailure?, stranger: Bool) {
        guard let client = client as? ScalarClient else { return (.unexpected("not a television's client"), false) }
        do {
            _ = try await client.powerStatus(timeout: probeTimeout)
            return (nil, false)
        } catch {
            return ((error as? any DeviceError)?.failure ?? .unexpected(String(describing: error)), false)
        }
    }
}
