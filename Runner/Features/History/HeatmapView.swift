import SwiftUI

struct HeatmapView: View {
    let weeks: [[DaySnapshot?]]
    let goal: Int
    let onSelect: (Date) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(weeks.indices, id: \.self) { week in
                VStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { day in
                        cell(weeks[week][day])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ snapshot: DaySnapshot?) -> some View {
        if let snapshot {
            Button { onSelect(snapshot.date) } label: {
                RoundedRectangle(cornerRadius: 3)
                    .fill(snapshot.points > 0
                          ? Color.rLime.opacity(HistoryMath.intensity(points: snapshot.points, goal: goal))
                          : Color.rSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(snapshot.isGold ? Color.rLime : Color.rBorder,
                                    lineWidth: snapshot.isGold ? 1.5 : 0.5)
                    )
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.clear)
                .frame(width: 16, height: 16)
        }
    }
}
