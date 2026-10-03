import Foundation
import XCTest

/// Loads the conformance vectors in docs/port, which are generated from the Python implementation that talks
/// to the real recorder (`bdzbridge/tools/portkit.py`). See docs/porting.md.
enum Vectors {
    static let directory: URL = {
        var url = URL(fileURLWithPath: #filePath)
        // .../app/RecorderKit/Tests/RecorderKitTests/Vectors.swift -> repository root
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("docs/port")
    }()

    static func load(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VectorError.shape(name)
        }
        return object
    }

    /// What the recorder of the vectors says of itself at description.xml (description.json), under `udn` in
    /// place of its own when one is given.
    static func descriptionXML(udn: String? = nil) throws -> String {
        let vector = try load("description.json")
        let xml = vector.string("description_xml")
        guard let udn else { return xml }
        return xml.replacingOccurrences(of: vector.dictionary("expected").string("udn"), with: udn)
    }

    enum VectorError: Error { case shape(String) }
}

extension Dictionary where Key == String, Value == Any {
    func dictionary(_ key: String) -> [String: Any] { self[key] as? [String: Any] ?? [:] }
    func list(_ key: String) -> [Any] { self[key] as? [Any] ?? [] }
    func dictionaries(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
    func string(_ key: String) -> String { self[key] as? String ?? "" }
    func int(_ key: String) -> Int? { self[key] as? Int }
    func bool(_ key: String) -> Bool { self[key] as? Bool ?? false }
}
