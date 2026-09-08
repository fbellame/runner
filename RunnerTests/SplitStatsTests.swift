import Testing
import Foundation
@testable import Runner

struct SplitStatsTests {
    @Test func emptyInputProducesEmptyAnalysisAndNoCrash() {
        let analysis = SplitStats.analyze([])

        #expect(analysis.splits.isEmpty)
        #expect(analysis.fastestKmIndex == nil)
        #expect(analysis.slowestKmIndex == nil)
        #expect(analysis.averageSecPerKm == nil)
        #expect(analysis.negativeSplit == .notApplicable)
    }

    @Test func singleSplitIsBothFastestAndSlowest() throws {
        let analysis = SplitStats.analyze([305])
        let split = try #require(analysis.splits.first)

        #expect(analysis.splits.count == 1)
        #expect(split.km == 1)
        #expect(split.seconds == 305)
        #expect(split.deltaFromAverage == 0)
        #expect(split.isFastest)
        #expect(split.isSlowest)
        #expect(analysis.fastestKmIndex == 0)
        #expect(analysis.slowestKmIndex == 0)
        #expect(analysis.averageSecPerKm == 305)
        #expect(analysis.negativeSplit == .notApplicable)
    }

    @Test func multiKilometerAnalysisComputesAverageIndicesAndDeltas() {
        let analysis = SplitStats.analyze([300, 315, 290, 330])

        #expect(analysis.splits.count == 4)
        #expect(analysis.averageSecPerKm == 308.75)
        #expect(analysis.fastestKmIndex == 2)
        #expect(analysis.slowestKmIndex == 3)
        #expect(analysis.splits.map(\.deltaFromAverage) == [-8.75, 6.25, -18.75, 21.25])
        #expect(analysis.splits[2].isFastest)
        #expect(analysis.splits[3].isSlowest)
    }

    @Test func fastestTieResolvesToEarliestKilometer() {
        let analysis = SplitStats.analyze([310, 295, 295, 320])

        #expect(analysis.fastestKmIndex == 1)
        #expect(analysis.splits[1].isFastest)
        #expect(analysis.splits[2].isFastest == false)
    }

    @Test func invalidSplitsAreFilteredBeforeAverageAndMinMax() {
        let analysis = SplitStats.analyze([0, 300, -4, 280])

        #expect(analysis.splits.count == 2)
        // km 2 and km 4 — the kilometres these splits actually are. Labelling
        // them 1 and 2 renumbered every split after a dropped one, in the list,
        // on the chart's x-axis and in the "Fastest km · Km N" highlight.
        #expect(analysis.splits.map(\.km) == [2, 4])
        #expect(analysis.splits.map(\.seconds) == [300, 280])
        #expect(analysis.averageSecPerKm == 290)
        #expect(analysis.fastestKmIndex == 1)
        #expect(analysis.slowestKmIndex == 0)
    }

    @Test func fasterSecondHalfIsNegativeSplitWithDelta() {
        let analysis = SplitStats.analyze([320, 315, 300, 295])

        #expect(analysis.negativeSplit == .negative(deltaSeconds: 20))
    }

    @Test func slowerSecondHalfIsPositiveSplitWithDelta() {
        let analysis = SplitStats.analyze([295, 300, 315, 320])

        #expect(analysis.negativeSplit == .positive(deltaSeconds: 20))
    }

    @Test func halfComparisonWithinTwoSecondsIsEven() {
        let analysis = SplitStats.analyze([300, 301, 302, 303])

        #expect(analysis.negativeSplit == .even)
    }

    @Test func oddSplitCountDropsMiddleKilometerBeforeHalfComparison() {
        let analysis = SplitStats.analyze([300, 300, 1_000, 290, 290])

        #expect(analysis.negativeSplit == .negative(deltaSeconds: 10))
    }

    @Test func exactlyTwoSplitsCompareFirstKilometerToSecond() {
        let analysis = SplitStats.analyze([305, 300])

        #expect(analysis.negativeSplit == .negative(deltaSeconds: 5))
    }
}
