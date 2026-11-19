import AirGuitarCore
import XCTest

final class ListeningGestureTests: XCTestCase {
    func testTwoWristMovementsPlayDifferentArticulationsOverTheSameRecording() {
        var motion = MotionInterpreter(sensitivity: .high, assisted: true)
        motion.prepareForSession()
        var instrument = AssistedPerformance()
        var phrases: [AssistedPhrase] = []
        for frame in 0..<300 {
            let rotation: Double
            switch frame {
            case 50..<57: rotation = 0.9
            case 175..<182: rotation = -1.9
            default: rotation = 0
            }
            let sample = MotionSample(timestamp: Double(frame) / 100, roll: 0,
                                      accelerationX: 0, accelerationY: 0, accelerationZ: 0,
                                      rotationX: rotation, rotationY: 0, rotationZ: 0)
            if let gesture = motion.consume(sample) {
                phrases.append(instrument.listeningPhrase(at: gesture.timestamp, velocity: gesture.velocity,
                                                          source: .detected(.d), accentOffsets: [0.38, 0.92]))
            }
        }
        XCTAssertEqual(phrases.map(\.isArpeggio), [true, false])
        XCTAssertEqual(phrases.map(\.chord), [.d, .d])
        XCTAssertEqual(phrases.map { $0.hits.first?.offset }, [0, 0])
        XCTAssertEqual(phrases.map { $0.hits.count }, [3, 2])
    }
}
