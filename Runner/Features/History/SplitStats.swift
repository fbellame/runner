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
        let valid = splitSeconds.filter { $0 > 0 }
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

        let splits = valid.enumerated().map { index, seconds in
            SplitDetail(km: index + 1,
                        seconds: seconds,
                        deltaFromAverage: seconds - average,
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
