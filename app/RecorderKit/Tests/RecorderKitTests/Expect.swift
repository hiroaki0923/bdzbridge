import XCTest

/// `XCTAssertEqual` for a value that has to be awaited, and the three beside it for theirs. XCTest's own take
/// their arguments as autoclosures, which cannot await, so each such check took a line to read the value and
/// another to compare it. An ordinary argument is read before the call, and a failure is still reported at
/// the line that asked.
func expectEqual<T: Equatable>(_ value: T, _ expected: T, _ message: @autoclosure () -> String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(value, expected, message(), file: file, line: line)
}

func expectTrue(_ value: Bool, _ message: @autoclosure () -> String = "",
                file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value, message(), file: file, line: line)
}

func expectFalse(_ value: Bool, _ message: @autoclosure () -> String = "",
                 file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(value, message(), file: file, line: line)
}

func expectNil<T>(_ value: T?, _ message: @autoclosure () -> String = "",
                  file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNil(value, message(), file: file, line: line)
}
