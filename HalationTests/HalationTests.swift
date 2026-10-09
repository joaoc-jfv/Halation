import Foundation
import Testing
@testable import Halation

@Suite struct SkeletonTests {
    @Test func bundleIdentifier() {
        #expect(Bundle.main.bundleIdentifier == "com.joaocadide.halation")
    }
}
