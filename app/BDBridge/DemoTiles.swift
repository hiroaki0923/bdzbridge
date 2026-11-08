import Foundation
import RecorderKit
import UIKit

/// The logo tiles drawn for the demo's guide, which the package writes into the demo's cache (`DemoLineUp.seed`).
extension DemoData {
    /// Writes the invented guide into the app's own cache, which is where the screens read it from
    /// (`DemoLineUp.seed`), with a coloured tile drawn for each station's logo.
    @MainActor
    static func seed(store: GuideStore) async throws {
        try await DemoLineUp.seed(store, logo: logo)
    }

    /// The tile for a station: its two characters, white on a colour the station's place in the line-up picks.
    @MainActor
    static func logo(_ text: String, _ index: Int) -> Data? {
        tile(text, colour: tileColours[index % tileColours.count])
    }

    private static let tileColours: [UIColor] = [
        UIColor(red: 0.20, green: 0.44, blue: 0.80, alpha: 1),
        UIColor(red: 0.16, green: 0.58, blue: 0.42, alpha: 1),
        UIColor(red: 0.84, green: 0.36, blue: 0.24, alpha: 1),
        UIColor(red: 0.45, green: 0.32, blue: 0.70, alpha: 1),
        UIColor(red: 0.84, green: 0.60, blue: 0.16, alpha: 1),
        UIColor(red: 0.24, green: 0.55, blue: 0.62, alpha: 1),
    ]

    @MainActor
    private static func tile(_ text: String, colour: UIColor) -> Data? {
        let size = CGSize(width: 64, height: 36)
        return UIGraphicsImageRenderer(size: size).pngData { context in
            colour.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let bounds = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: (size.width - bounds.width) / 2,
                                                y: (size.height - bounds.height) / 2),
                                    withAttributes: attributes)
            _ = context
        }
    }
}
