import Testing
@testable import Runner

struct FormatTests {
    @Test func durationFormats() {
        #expect(Format.duration(0) == "0:00")
        #expect(Format.duration(332) == "5:32")
        #expect(Format.duration(3_849) == "1:04:09")
    }

    @Test func paceFormats() {
        #expect(Format.pace(332) == "5:32 /km")
        #expect(Format.pace(nil) == "—")
    }

    @Test func kmUsesTwoDecimals() {
        let s = Format.km(2_100)
        #expect(s.contains("2") && s.contains("10") && s.contains("km"))
    }
}
