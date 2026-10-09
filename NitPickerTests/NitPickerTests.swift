import Foundation
import Testing
@testable import NitPicker

@Suite struct SkeletonTests {
    @Test func bundleIdentifier() {
        #expect(Bundle.main.bundleIdentifier == "com.joaocadide.nitpicker")
    }
}
