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

    @Test func kcalFormatsWithEstimateMarker() {
        #expect(Format.kcal(130) == "130 kcal")
        #expect(Format.kcal(130, estimated: true) == "~130 kcal")
    }

    @Test func co2FormatsAsKilograms() {
        // Decimal separator is locale-dependent (","/".") — assert digits + unit, not the separator.
        let a = Format.co2(grams: 900)
        #expect(a.contains("0") && a.contains("9") && a.hasSuffix(" kg"))
        let b = Format.co2(grams: 1500)
        #expect(b.contains("1") && b.contains("5") && b.hasSuffix(" kg"))
    }
}
