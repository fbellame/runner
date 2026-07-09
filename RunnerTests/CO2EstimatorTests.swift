import Testing
@testable import Runner

struct CO2EstimatorTests {
    @Test func bikeDistanceMapsToCarGramsAvoided() {
        // 5 km by bike -> 5 x 192 g = 960 g avoided.
        let grams = CO2Estimator.avoidedGrams(type: .bike, distanceMeters: 5000)
        #expect(abs(grams - 960.0) < 0.001)
    }

    @Test func nonBikeTypesAvoidNothing() {
        #expect(CO2Estimator.avoidedGrams(type: .run, distanceMeters: 5000) == 0)
        #expect(CO2Estimator.avoidedGrams(type: .walk, distanceMeters: 5000) == 0)
    }

    @Test func nonPositiveDistanceAvoidsNothing() {
        #expect(CO2Estimator.avoidedGrams(type: .bike, distanceMeters: 0) == 0)
        #expect(CO2Estimator.avoidedGrams(type: .bike, distanceMeters: -100) == 0)
    }

    @Test func factorIsTheDocumentedAverageCar() {
        #expect(CO2Estimator.carGramsPerKm == 192.0)
    }
}
