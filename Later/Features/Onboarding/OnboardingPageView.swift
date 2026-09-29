import SwiftUI

enum OnboardingIllustration {
    case cards
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

struct ShareOnboardingPageView: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 12)

            VStack(spacing: 8) {
                Text("Important? Send it right away.")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)

                Text("Share a screenshot to Later for immediate processing. We’ll notify you when it’s ready.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            .padding(.horizontal, 26)

            SharePhoneIllustration()
                .frame(height: 292)

            Label("No rush? Later also scans new screenshots automatically.", systemImage: "photo.stack")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Spacer(minLength: 6)
        }
    }
}

private struct SharePhoneIllustration: View {
    var body: some View {
        ZStack(alignment: .top) {
            phone
                .padding(.top, 22)

            notification
                .frame(width: 258)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A screenshot shared to Later, followed by a Saved to Later notification")
    }

    private var phone: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color.primary.opacity(0.9))

            ZStack(alignment: .bottom) {
                screenshot
                shareSheet
            }
            .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
            .padding(5)

            Capsule()
                .fill(.black)
                .frame(width: 64, height: 16)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 8)
        }
        .frame(width: 176, height: 270)
        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
    }

    private var screenshot: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [Color.cyan.opacity(0.55), Color.blue.opacity(0.22), Color.indigo.opacity(0.48)],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(alignment: .bottom, spacing: 5) {
                ForEach([62.0, 88.0, 70.0, 104.0, 78.0, 92.0], id: \.self) { height in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.32))
                        .frame(width: 19, height: height)
                }
            }
            .offset(y: -72)

            Rectangle()
                .fill(Color.blue.opacity(0.42))
                .frame(height: 88)

            Image(systemName: "photo.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .padding(.bottom, 104)
        }
    }

    private var shareSheet: some View {
        VStack(spacing: 9) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 30, height: 4)

            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.blue.opacity(0.28))
                    .frame(width: 31, height: 38)
                    .overlay(Image(systemName: "photo.fill").font(.caption).foregroundStyle(.white))

                Text("Screenshot")
                    .font(.caption.weight(.semibold))
                Spacer()
            }

            Divider()

            HStack(alignment: .top, spacing: 15) {
                ShareTarget(label: "AirDrop", systemImage: "airdrop", tint: .blue)
                LaterShareTarget()
                ShareTarget(label: "Messages", systemImage: "message.fill", tint: .green)
                ShareTarget(label: "More", systemImage: "ellipsis", tint: .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .topLeading) {
            Image(systemName: "arrow.turn.down.right")
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.accentColor)
                .offset(x: 60, y: 77)
        }
    }

    private var notification: some View {
        HStack(spacing: 10) {
            Image("LaterAppIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("LATER")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("now")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("Saved to Later")
                    .font(.caption.weight(.semibold))
                Text("Chicago River architecture cruise")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.14), radius: 14, y: 7)
    }
}

private struct ShareTarget: View {
    let label: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(tint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(label)
                .font(.system(size: 7))
                .lineLimit(1)
        }
        .frame(width: 34)
    }
}

private struct LaterShareTarget: View {
    var body: some View {
        VStack(spacing: 4) {
            Image("LaterAppIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .padding(-4)
                }
            Text("Later")
                .font(.system(size: 7))
        }
        .frame(width: 34)
    }
}
