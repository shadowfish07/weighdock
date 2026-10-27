import Foundation
import Testing

// Lightweight spelling bridge for the upstream fixture assertions. Swift Testing
// is bundled with Command Line Tools; XCTest requires the full Xcode installation.
func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual == expected, Comment(rawValue: message), sourceLocation: sourceLocation)
}
func XCTAssertEqual(_ actual: Double, _ expected: Double, accuracy: Double, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(actual - expected) <= accuracy, sourceLocation: sourceLocation)
}
func XCTAssertTrue(_ condition: Bool, sourceLocation: SourceLocation = #_sourceLocation) { #expect(condition, sourceLocation: sourceLocation) }
func XCTAssertFalse(_ condition: Bool, sourceLocation: SourceLocation = #_sourceLocation) { #expect(!condition, sourceLocation: sourceLocation) }
func XCTAssertNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) { #expect(value == nil, sourceLocation: sourceLocation) }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(throws: (any Error).self, Comment(rawValue: message), sourceLocation: sourceLocation) { _ = try expression() }
}
func XCTAssertLessThanOrEqual<T: Comparable>(_ actual: T, _ expected: T, sourceLocation: SourceLocation = #_sourceLocation) { #expect(actual <= expected, sourceLocation: sourceLocation) }
func XCTAssertGreaterThan<T: Comparable>(_ actual: T, _ expected: T, sourceLocation: SourceLocation = #_sourceLocation) { #expect(actual > expected, sourceLocation: sourceLocation) }
