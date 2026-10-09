import CoreMedia
import Testing
@testable import NitPicker

@Suite struct TimeFormattingTests {
    @Test func formatsMinutesAndSeconds() {
        #expect(Duration.seconds(0).clockString == "0:00")
        #expect(Duration.seconds(65.9).clockString == "1:05")
    }

    @Test func formatsHours() {
        #expect(Duration.seconds(3600).clockString == "1:00:00")
        #expect(Duration.seconds(7384).clockString == "2:03:04")
    }

    @Test func clampsNegativeAndNonFinite() {
        #expect(Duration.seconds(-5).clockString == "0:00")
    }
}

@Suite struct DurationConversionTests {
    @Test func roundTripsThroughCMTime() throws {
        let time = Duration.seconds(12.5).cmTime
        #expect(abs(time.seconds - 12.5) < 0.001)
        #expect(try #require(Duration(time)).seconds == 12.5)
    }

    @Test func rejectsNonNumericTimes() {
        #expect(Duration(CMTime.invalid) == nil)
        #expect(Duration(CMTime.indefinite) == nil)
    }
}

@Suite struct CodecNamesTests {
    @Test func mapsKnownCodes() {
        #expect(CodecNames.displayName(forFourCC: 0x6176_6331) == "H.264")   // avc1
        #expect(CodecNames.displayName(forFourCC: 0x6876_6331) == "HEVC")    // hvc1
        #expect(CodecNames.displayName(forFourCC: 0x6563_2D33) == "E-AC-3")  // ec-3
    }

    @Test func fallsBackToRawCode() {
        #expect(CodecNames.displayName(forFourCC: 0x7A7A_7A7A) == "zzzz")
        #expect(CodecNames.fourCC(0x0000_0001) == "0x1")
    }
}

