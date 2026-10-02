import Foundation

/// What the app is doing with the recorder, as a list of lines rather than a single one.
///
/// Saving one shared line and putting it back afterwards is right only for work that nests, and work here
/// does not: the client answers its requests in the order they arrive, so the piece begun first usually
/// finishes first. So each piece of work holds a token for a line of its own, and changes and takes away
/// only that line. Here rather than in the app so that `swift test` can check it without a simulator.
public struct Activities: Sendable, Equatable {
    /// Which line is whose. Issued by `begin` and good for nothing else.
    public struct Token: Hashable, Sendable {
        fileprivate let serial: Int
    }

    private struct Line: Sendable, Equatable {
        let token: Token
        var text: String
    }

    private var lines: [Line] = []
    private var issued = 0

    public init() {}

    /// The line to show: whatever was begun most recently of what is still under way, or nil when nothing
    /// is. The latest is what the reader has just asked for, so it is the one they are looking for.
    public var current: String? { lines.last?.text }

    public var isEmpty: Bool { lines.isEmpty }

    /// Puts up a line and returns the token that changes it and takes it away.
    public mutating func begin(_ text: String) -> Token {
        issued += 1
        let token = Token(serial: issued)
        lines.append(Line(token: token, text: text))
        return token
    }

    /// Changes one line where it stands. A countdown, or a longer piece of work saying which step it has
    /// reached, keeps its place behind anything begun after it rather than jumping in front of it. A line
    /// already taken away stays away: a late update does not bring it back.
    public mutating func update(_ token: Token, to text: String) {
        guard let index = lines.firstIndex(where: { $0.token == token }) else { return }
        lines[index].text = text
    }

    /// Takes one line away, wherever it is in the list. Ending a token that has already been ended does
    /// nothing, so a path that ends early and a `defer` that ends again are both safe.
    public mutating func end(_ token: Token) {
        lines.removeAll { $0.token == token }
    }
}
