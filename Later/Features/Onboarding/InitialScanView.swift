import SwiftUI

struct InitialScanView: View {
    @ObservedObject var coordinator: ScreenshotDiscoveryCoordinator
    let continueAction: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.13), lineWidth: 16)
                Circle()
                    .trim(from: 0, to: coordinator.progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth, value: coordinator.progress)
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 174, height: 174)

            VStack(spacing: 10) {
                Text("Finding things you saved…")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("Later is organizing your screenshots. You can continue now and use the app while it finishes.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Continue", action: continueAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Spacer()
        }
        .padding(28)
    }
}
