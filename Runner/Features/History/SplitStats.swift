import Foundation

struct SplitDetail: Identifiable {
    let km: Int
    let seconds: Double
    let deltaFromAverage: Double
    let isFastest: Bool
    let isSlowest: Bool

    var id: Int { km }
}

enum NegativeSplit: Equatable {
    case negative(deltaSeconds: Double)
    case positive(deltaSeconds: Double)
    case even
    case notApplicable
}

struct SplitAnalysis {
    let splits: [SplitDetail]
    let fastestKmIndex: Int?
    let slowestKmIndex: Int?
    let averageSecPerKm: Double?
    let negativeSplit: NegativeSplit
}

enum SplitStats {
    private static let negativeSplitBandSecPerKm = 2.0

    static func analyze(_ splitSeconds: [Double]) -> SplitAnalysis {
        // Enumerate BEFORE filtering: the label is the kilometre this split
        // actually is, not its position among the survivors. Dropping split 3
        // used to renumber every later one down by a kilometre, in the list,
        // on the chart's x-axis and in the "Fastest km · Km N" highlight.
        let kept = splitSeconds.enumerated().filter { $0.element > 0 }
        let valid = kept.map(\.element)
        guard !valid.isEmpty else {
            return SplitAnalysis(splits: [],
                                 fastestKmIndex: nil,
                                 slowestKmIndex: nil,
                                 averageSecPerKm: nil,
                                 negativeSplit: .notApplicable)
        }

        let average = valid.reduce(0, +) / Double(valid.count)
        var fastestIndex = 0
        var slowestIndex = 0
        for index in valid.indices.dropFirst() {
            if valid[index] < valid[fastestIndex] {
                fastestIndex = index
            }
            if valid[index] > valid[slowestIndex] {
                slowestIndex = index
            }
        }

        let splits = kept.enumerated().map { index, entry in
            SplitDetail(km: entry.offset + 1,
                        seconds: entry.element,
                        deltaFromAverage: entry.element - average,
                        isFastest: index == fastestIndex,
                        isSlowest: index == slowestIndex)
        }

        return SplitAnalysis(splits: splits,
                             fastestKmIndex: fastestIndex,
                             slowestKmIndex: slowestIndex,
                             averageSecPerKm: average,
                             negativeSplit: negativeSplit(for: valid))
    }

    private static func negativeSplit(for splits: [Double]) -> NegativeSplit {
        guard splits.count >= 2 else { return .notApplicable }

        let halfCount = splits.count / 2
        let firstHalfAvg = splits.prefix(halfCount).reduce(0, +) / Double(halfCount)
        let secondHalfAvg = splits.suffix(halfCount).reduce(0, +) / Double(halfCount)
        let delta = firstHalfAvg - secondHalfAvg

        if delta > negativeSplitBandSecPerKm {
            return .negative(deltaSeconds: delta)
        }
        if delta < -negativeSplitBandSecPerKm {
            return .positive(deltaSeconds: -delta)
        }
        return .even
    }
}
