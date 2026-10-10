import Foundation
import RecorderKit
import XCTest
@testable import BDBridge

/// The recorder's work over many recordings, each run asked for as a screen asks for it -- the bulk delete, the
/// bulk protect and the scan for duplicates: what a run asks of the recorder for each recording and in which
/// order, what its job says while it runs and once it has ended, and what silence, 中止, leaving the app, a check
/// beside it and another recorder's arrival each do to it.
///
/// Gates, as `FunnelGateTests` is and for the same kind of move: each pins what the app does today, so that a
/// run's steps can move out of the model and into RecorderKit with the test's body unchanged, and where a test
/// holds something that is still to be changed on purpose it says so, and that change rewrites it. A test asks
/// only what a screen asks and reads only what a screen reads, with the bench's own words for the rest (`Said`,
/// `Ask`, `makeSure`).
///
/// The recorder is the bench's (`NamedRecorder`), told what to answer a request at a time.
@MainActor
final class RunGateTests: XCTestCase {}
