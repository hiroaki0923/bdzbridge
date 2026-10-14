import Foundation
import RecorderKit
import SwiftUI

/// The recorder's own keyword conditions (おまかせ・まる録): read, added and removed, never changed.
extension AppModel {
    func loadRecorderRules() async { await recorderHost.loadRecorderRules() }

    /// What pulling the conditions down asks for (`RecorderHost.refreshRecorderRules`).
    func refreshRecorderRules() async { await recorderHost.refreshRecorderRules() }

    /// The disk a condition's row names, or nil for none: only one off the internal disk, by the one rule the
    /// reservations' rows go by (`RecorderDisk.shown`).
    func diskShown(_ rule: RecorderRule) -> String? {
        RecorderDisk.shown(rule.destination, on: .recorder, usb: usbDisk)
    }

    /// Registers a condition on the recorder itself (`RecorderHost.addRecorderRule`).
    func addRecorderRule(_ request: RecorderRuleRequest) async -> Altered {
        await recorderHost.addRecorderRule(request)
    }

    /// Delete only, never edit (`RecorderHost.removeRecorderRule`).
    func removeRecorderRule(_ rule: RecorderRule) async -> Altered { await recorderHost.removeRecorderRule(rule) }
}
