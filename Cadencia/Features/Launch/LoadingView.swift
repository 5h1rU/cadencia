import SwiftUI

/// Matches the system launch screen; only the running app displays progress and an escape route.
struct LoadingView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var onContinue: (() -> Void)?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color("LaunchBackground").ignoresSafeArea()

                if dynamicTypeSize.isAccessibilitySize {
                    ScrollView {
                        VStack(spacing: 48) {
                            brand
                            progress
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 40)
                        .frame(maxWidth: 420)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    }
                } else {
                    brand
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2 - 40)

                    progress
                        .padding(.horizontal, 32)
                        .frame(maxWidth: 420)
                        .padding(.bottom, 40)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }

    private var brand: some View {
        VStack(spacing: 24) {
            Image("BrandIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                .accessibilityHidden(true)

            Text(verbatim: "Cadencia")
                .font(.system(size: 34, weight: .semibold))
        }
    }

    private var progress: some View {
        VStack(spacing: 16) {
            ProgressView("Syncing your training…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .tint(.accentColor)

            if let onContinue {
                Button(action: onContinue) {
                    // The 44 pt target must be inside the label: a frame around the button is not tappable.
                    Text("Open Cadencia")
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .font(.subheadline.weight(.medium))
                Text("Your training will keep syncing in the background.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
    }
}

#Preview("Loading · light") {
    LoadingView(onContinue: {})
        .preferredColorScheme(.light)
}

#Preview("Loading · dark · Spanish") {
    LoadingView(onContinue: {})
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: "es"))
}
