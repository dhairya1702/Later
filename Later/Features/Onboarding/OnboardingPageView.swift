import SwiftUI

enum OnboardingIllustration {
    case cards
    case facts
    case privacy
}

struct OnboardingPageView: View {
    let symbol: String
    let title: String
    let message: String
    let illustration: OnboardingIllustration

    var body: some View {
        VStack(spacing: 30) {
            Spacer(minLength: 24)
            illustrationView
                .frame(height: 250)
            VStack(spacing: 14) {
                Label(title, systemImage: symbol)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                    .labelStyle(.titleOnly)
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .padding(.horizontal, 28)
            Spacer(minLength: 12)
        }
    }

    @ViewBuilder
    private var illustrationView: some View {
        switch illustration {
        case .cards:
            ZStack {
                SampleCard(title: "$15 off", detail: "Code SAVE15", icon: "tag.fill", color: .red)
                    .rotationEffect(.degrees(-8)).offset(x: -62, y: 18)
                SampleCard(title: "Concert", detail: "Friday · 7:30 PM", icon: "music.mic", color: .pink)
                    .rotationEffect(.degrees(7)).offset(x: 62, y: 18)
                SampleCard(title: "Home idea", detail: "Inspiration", icon: "sparkles", color: Color.accentColor)
                    .offset(y: -35)
            }
        case .facts:
            VStack(spacing: 12) {
                FactPill(icon: "calendar", text: "Friday, October 15")
                FactPill(icon: "clock.fill", text: "7:30 PM")
                FactPill(icon: "tag.fill", text: "25% off · SAVE25")
                FactPill(icon: "mappin.circle.fill", text: "United Center")
            }
        case .privacy:
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.14)).frame(width: 220, height: 220)
                Circle().fill(Color.accentColor.opacity(0.16)).frame(width: 158, height: 158)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 82, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

private struct SampleCard: View {
    let title: String
    let detail: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 128, alignment: .leading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: color.opacity(0.16), radius: 18, y: 8)
    }
}

private struct FactPill: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.headline)
            .foregroundStyle(.primary, Color.accentColor)
            .frame(maxWidth: 270, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background(.regularMaterial, in: Capsule())
    }
}
