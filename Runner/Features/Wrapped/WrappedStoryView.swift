import SwiftUI

struct WrappedStoryView: View {
    let wrapped: MonthWrapped

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex = 0
    @State private var isTouching = false
    @State private var cardAppeared = false

    private var currentCard: WrappedCard {
        wrapped.cards[currentIndex]
    }

    private var progressTaskID: String {
        "\(currentIndex)-\(isTouching)"
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.rBackground, Color.rSurface, Color.rBackground],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    ForEach(Array(wrapped.cards.indices), id: \.self) { index in
                        Capsule()
                            .fill(index <= currentIndex ? Color.rLime : Color.white.opacity(0.18))
                            .frame(height: 4)
                    }
                }
                .padding(.top, 14)
                .padding(.horizontal, 18)

                HStack {
                    Text(monthTitle)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.rTextSecondary)
                        .textCase(.uppercase)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                    }
                    .accessibilityLabel(String(localized: "Close"))
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)

                Spacer(minLength: 18)

                WrappedCardView(card: currentCard, month: wrapped.month)
                    .id(currentIndex)
                    .scaleEffect(cardAppeared ? 1 : 0.94)
                    .opacity(cardAppeared ? 1 : 0)
                    .padding(.horizontal, 18)

                Spacer(minLength: 24)
            }

            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: previous)
                    .simultaneousGesture(touchGesture)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: next)
                    .simultaneousGesture(touchGesture)
            }
            .padding(.top, 72)
            .padding(.bottom, 20)
        }
        .preferredColorScheme(.dark)
        .onAppear { showCurrentCard() }
        .onChange(of: currentIndex) { _, _ in showCurrentCard() }
        .task(id: progressTaskID) {
            guard !isTouching else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, !isTouching else { return }
            next()
        }
    }

    private var monthTitle: String {
        wrapped.month.startDate(calendar: .current).formatted(.dateTime.month(.wide).year())
    }

    private var touchGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in isTouching = true }
            .onEnded { _ in isTouching = false }
    }

    private func showCurrentCard() {
        cardAppeared = false
        withAnimation(.spring(duration: 0.42, bounce: 0.18)) {
            cardAppeared = true
        }
    }

    private func previous() {
        guard currentIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.2)) { currentIndex -= 1 }
    }

    private func next() {
        guard currentIndex < wrapped.cards.count - 1 else {
            dismiss()
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) { currentIndex += 1 }
    }
}

private struct WrappedCardView: View {
    let card: WrappedCard
    let month: WrappedMonth

    var body: some View {
        switch card {
        case .intro:
            introCard
        case .totals(let totals):
            totalsCard(totals)
        case .highlights(let longestWorkouts, let personalRecords):
            highlightsCard(longestWorkouts, personalRecords: personalRecords)
        case .badges(let badges):
            badgesCard(badges)
        case .consistency(let consistency):
            consistencyCard(consistency)
        case .impact(let impact):
            impactCard(impact)
        case .finale(let finale):
            finaleCard(finale)
        }
    }

    private var introCard: some View {
        storyCard(accent: .rLime) {
            Spacer()
            Text(month.startDate(calendar: .current)
                .formatted(.dateTime.month(.wide).year())
                .uppercased())
                .font(.system(size: 38, weight: .black, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Text(String(localized: "Wrapped"))
                .font(.system(size: 60, weight: .black, design: .rounded))
                .foregroundStyle(Color.rLime)
                .modifier(GlowShadow(color: .rLime))
            Text(String(localized: "Your month in motion"))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.rTextSecondary)
                .padding(.top, 8)
            Spacer()
        }
    }

    private func totalsCard(_ totals: WrappedTotals) -> some View {
        storyCard(accent: .rTeal) {
            cardLabel(String(localized: "Your month"))
            Text(Format.km(totals.distanceMeters))
                .font(.system(size: 44, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Text(String(localized: "Distance"))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.rTextSecondary)
            if let delta = totals.distanceDeltaFraction {
                deltaLabel(delta)
                    .padding(.top, 10)
            }
            HStack(spacing: 12) {
                metric(value: "\(totals.workoutCount)", label: String(localized: "Workouts"), accent: .rPurple)
                metric(value: Format.duration(totals.movingSeconds), label: String(localized: "Active time"), accent: .rTeal)
            }
            .padding(.top, 24)
        }
    }

    private func highlightsCard(_ longestWorkouts: [WrappedLongestWorkout],
                                personalRecords: [WrappedPersonalRecord]) -> some View {
        storyCard(accent: .rOrange) {
            if !personalRecords.isEmpty {
                CelebrationBurst()
            }
            cardLabel(String(localized: "Highlights"))
            Text(String(localized: "Your longest efforts"))
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            ForEach(Array(longestWorkouts.enumerated()), id: \.offset) { _, workout in
                HStack {
                    Text(workout.type.emoji).font(.system(size: 22))
                    Text(workout.type.localizedName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Spacer()
                    Text(Format.km(workout.distanceMeters, estimated: workout.distanceEstimated))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(workout.type.accent)
                }
                .padding(.vertical, 5)
            }
            if !personalRecords.isEmpty {
                Divider().overlay(Color.rBorder).padding(.vertical, 8)
                Text(String(format: String(localized: "%lld new personal records"), Int64(personalRecords.count)))
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundStyle(Color.rLime)
                ForEach(personalRecords, id: \.id) { item in
                    Text("\(item.type.emoji) \(recordTitle(item.record.kind))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.rTextSecondary)
                }
            }
        }
    }

    private func badgesCard(_ badges: [Badge]) -> some View {
        storyCard(accent: .rLime) {
            CelebrationBurst()
            cardLabel(String(localized: "Badges unlocked"))
            Text(String(format: String(localized: "%lld new badges"), Int64(badges.count)))
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: min(3, badges.count)), spacing: 12) {
                ForEach(badges) { badge in
                    VStack(spacing: 6) {
                        Text("🏆")
                            .font(.system(size: 32))
                            .frame(width: 54, height: 54)
                            .background(Circle().fill(badgeAccent(badge).opacity(0.18)))
                        Text(badgeTitle(badge))
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.top, 20)
        }
    }

    private func consistencyCard(_ consistency: WrappedConsistency) -> some View {
        storyCard(accent: .rPurple) {
            cardLabel(String(localized: "Consistency"))
            HStack(spacing: 12) {
                metric(value: "\(consistency.activeDays)", label: String(localized: "Active days"), accent: .rLime)
                metric(value: "\(consistency.bestStreak)", label: String(localized: "Best streak"), accent: .rOrange)
            }
            Text(String(localized: "Day by day"))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.rTextSecondary)
                .padding(.top, 22)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                ForEach(consistency.heatStrip) { day in
                    Text("\(Calendar.current.component(.day, from: day.date))")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(day.workoutCount > 0 ? Color.rBackground : Color.rTextSecondary)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(day.workoutCount > 0
                                  ? Color.rLime.opacity(min(1, 0.35 + Double(day.workoutCount) * 0.22))
                                  : Color.white.opacity(0.06)))
                }
            }
            .padding(.top, 6)
        }
    }

    private func impactCard(_ impact: WrappedImpact) -> some View {
        storyCard(accent: .rTeal) {
            cardLabel(String(localized: "Impact"))
            HStack(spacing: 12) {
                metric(value: Format.kcal(impact.calories), label: String(localized: "Calories burned"), accent: .rOrange)
                metric(value: Format.co2(grams: impact.co2SavedGrams), label: String(localized: "CO₂ saved"), accent: .rTeal)
            }
            if impact.co2SavedGrams > 0 {
                Text(String(format: String(localized: "≈ %@ not driven by car 🌱"),
                            Format.km(impact.carKilometers * 1_000)))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.rLime)
                    .padding(.top, 28)
            }
        }
    }

    private func finaleCard(_ finale: WrappedFinale) -> some View {
        storyCard(accent: .rLime) {
            Spacer()
            cardLabel(String(localized: "That was your month"))
            Text(Format.km(finale.distanceMeters))
                .font(.system(size: 44, weight: .black, design: .rounded))
                .foregroundStyle(Color.rLime)
            Text(String(format: String(localized: "%lld workouts across %lld active days"),
                        Int64(finale.workoutCount), Int64(finale.activeDays)))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            if finale.co2SavedGrams > 0 {
                Text("🌱 \(Format.co2(grams: finale.co2SavedGrams)) \(String(localized: "CO₂ saved"))")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.rTeal)
                    .padding(.top, 14)
            }
            Spacer()
        }
    }

    private func storyCard<Content: View>(accent: Color,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, minHeight: 420, alignment: .leading)
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 28).fill(Color.rSurface))
            .overlay(RoundedRectangle(cornerRadius: 28).stroke(accent.opacity(0.65), lineWidth: 1.5))
            .shadow(color: accent.opacity(0.18), radius: 24)
    }

    private func cardLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .black, design: .rounded))
            .tracking(2)
            .foregroundStyle(Color.rTextSecondary)
    }

    private func metric(value: String, label: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.rTextSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.05)))
    }

    private func deltaLabel(_ delta: Double) -> some View {
        let sign = delta > 0 ? "▲" : delta < 0 ? "▼" : ""
        let color: Color = delta > 0 ? .rLime : delta < 0 ? .rOrange : .rTextSecondary
        return Text("\(sign) \(abs(delta).formatted(.percent.precision(.fractionLength(0)))) \(String(localized: "vs last month"))")
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(color)
    }

    private func recordTitle(_ kind: RecordKind) -> String {
        switch kind {
        case .longestDistance: String(localized: "Longest distance")
        case .fastestOneKilometer: String(localized: "Fastest 1 km")
        case .fastestFiveKilometers: String(localized: "Fastest 5 km")
        case .bestAveragePace: String(localized: "Best average pace")
        }
    }

    private func badgeTitle(_ badge: Badge) -> String {
        switch badge.kind {
        case .distance: String(format: String(localized: "%lld km"), Int64(badge.threshold))
        case .count: String(format: String(localized: "%lld workouts"), Int64(badge.threshold))
        }
    }

    private func badgeAccent(_ badge: Badge) -> Color {
        switch badge.scope {
        case .global: .rLime
        case .perType(let type): type.accent
        }
    }
}
