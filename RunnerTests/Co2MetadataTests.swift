import Testing
@testable import Runner

struct Co2MetadataTests {
    @Test func readsGramsFromNumberInGrams() {
        // A large value is already grams.
        #expect(Co2Metadata.grams(from: ["CO2Emission": 480]) == 480)
    }

    @Test func treatsSmallValueAsKilograms() {
        // Bixi-style small value → kilograms → grams.
        let grams = Co2Metadata.grams(from: ["co2_saved_kg": 0.48])
        #expect(grams != nil && abs(grams! - 480) < 0.001)
    }

    @Test func parsesNumericString() {
        #expect(Co2Metadata.grams(from: ["carbonAvoided": "480"]) == 480)
    }

    @Test func caseInsensitiveKeyMatch() {
        #expect(Co2Metadata.grams(from: ["HKMetadataCo2Grams": 250]) == 250)
    }

    @Test func nilWhenNoCo2Key() {
        #expect(Co2Metadata.grams(from: ["HKElevationAscended": 12]) == nil)
        #expect(Co2Metadata.grams(from: nil) == nil)
    }

    @Test func nilWhenValueNotNumeric() {
        #expect(Co2Metadata.grams(from: ["co2": "n/a"]) == nil)
    }
}
