import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The recorder's two runs with no screen, each asked for as the app's own entries ask for it, with its
/// surroundings handed in -- the overnight run (`BackgroundWork.refresh`) and the Shortcuts action
/// (`BackgroundWork.sendWaiting`, and what it says, `SendWaitingIntent.saying`): what a run asks of the recorder
/// and in which order, what it tells and what it leaves untold, and what being cancelled, silence part-way,
/// nobody at the address and a recorder the cache is not of each come to.
///
/// Gates, as `RunGateTests` is: each pins what the app does today, so that the order of a run can move into
/// RecorderKit with the test's body unchanged, and where a test holds something that is still to be changed on
/// purpose it says so, and that change rewrites it. What a night told is read from the bench's record
/// (`Tellings`), which has each telling by the time it returns.
///
/// No MAC is handed to either run, as in `WhichRecorderNoScreenTests`: a run with no screen sends its packet
/// itself, not through the model, and a MAC would put one on the network this is run on.
@MainActor
final class NoScreenGateTests: XCTestCase {}
