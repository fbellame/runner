import SwiftUI

struct WrappedArchiveView: View {
    let summaries: [ActivityWorkoutSummary]

    @State private var selectedWrapped: MonthWrapped?
    private let seenStore = WrappedSeenStore()

    private var months: [WrappedMonth] {
        WrappedMath.availableMonths(summaries, asOf: .now, calendar: .current)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if months.isEmpty {
                    SurfaceCard {
                        Text(String(localized: "Your monthly stories will appear here after your first complete month."))
                            .font(.subheadline)
                            .foregroundStyle(Color.rTextSecondary)
                    }
                }
                ForEach(months, id: \.self) { month in
                    Button { open(month) } label: {
                        SurfaceCard {
                            HStack(spacing: 12) {
                                Text("✨")
                                    .font(.system(size: 26))
                                    .frame(width: 42, height: 42)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.rPurple.opacity(0.16)))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(month.startDate(calendar: .current)
                                        .formatted(.dateTime.month(.wide).year()))
                                        .font(.system(size: 17, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                    Text(String(localized: "View your Wrapped"))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.rTextSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color.rLime)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
        }
        .background(Color.rBackground)
        .navigationTitle(String(localized: "Monthly Wrapped"))
        .navigationBarTitleDisplayMode(.large)
        .fullScreenCover(item: $selectedWrapped) { wrapped in
            WrappedStoryView(wrapped: wrapped)
        }
    }

    private func open(_ month: WrappedMonth) {
        guard let wrapped = WrappedMath.monthWrapped(summaries, month: month, calendar: .current) else { return }
        seenStore.markSeen(month)
        selectedWrapped = wrapped
    }
}
