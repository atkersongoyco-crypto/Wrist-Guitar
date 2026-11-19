import XCTest
@testable import AirGuitarCore

final class AdaptiveStrokeDynamicsTests: XCTestCase {
    private func stroke(_ strength: Double, at time: Double = 1) -> StrumEvent {
        StrumEvent(timestamp: time, chord: .bMinor, velocity: 0.45 + 0.55 * strength)
    }

    func testWaitsForRepeatedEvidenceOfBothLevels() {
        var dynamics = AdaptiveStrokeDynamics()
        for i in 0..<100 {
            let event = stroke(i == 60 ? 0.99 : 0.30)
            XCTAssertEqual(dynamics.adjusted(event).velocity, event.velocity)
        }
        var beginner = AdaptiveStrokeDynamics()
        for i in 0..<16 {
            let event = stroke(i.isMultiple(of: 2) ? 0.22 : 0.59)
            XCTAssertEqual(beginner.adjusted(event).velocity, event.velocity)
        }
        var narrow = AdaptiveStrokeDynamics()
        for i in 0..<60 {
            let event = stroke(i.isMultiple(of: 2) ? 0.43 : 0.55)
            XCTAssertEqual(narrow.adjusted(event).velocity, event.velocity)
        }
    }

    func testLearnsWithoutShiftingTimingAndPreservesOrderAndEndpoints() {
        var dynamics = AdaptiveStrokeDynamics()
        var previous = 0.59
        for i in 0..<100 {
            let input = i.isMultiple(of: 2) ? 0.22 : 0.59
            let event = dynamics.adjusted(stroke(input, at: Double(i) / 4))
            XCTAssertEqual(event.chord, .bMinor)
            XCTAssertEqual(event.timestamp, Double(i) / 4)
            XCTAssertLessThanOrEqual(abs(event.pickStrength - input), 0.100_001)
            if !i.isMultiple(of: 2) {
                XCTAssertLessThanOrEqual(event.pickStrength - previous, 0.016)
                previous = event.pickStrength
            }
        }
        XCTAssertGreaterThan(previous, 0.65)
        var last = -1.0
        for step in 0...100 {
            let strength = Double(step) / 100
            var snapshot = dynamics
            let result = snapshot.adjusted(stroke(strength)).pickStrength
            XCTAssertGreaterThan(result, last)
            if step == 0 || step == 100 { XCTAssertEqual(result, strength, accuracy: 0.000_001) }
            last = result
        }
        let light = StrumEvent(timestamp: 12, chord: .c, velocity: 0.37)
        XCTAssertEqual(dynamics.adjusted(light).velocity, 0.37)
    }
}
