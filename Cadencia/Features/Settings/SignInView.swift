import SwiftUI
import CadenciaCore

/// First screen until the athlete is signed in with Intervals.icu through Cadencia's server, which gives the
/// session for the plan and the coach, and the Intervals.icu token for what this phone sends Intervals itself.
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "figure.indoor.cycle")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("Cadencia")
                        .font(.largeTitle.bold())
                    Text("Your Intervals.icu data, a daily prescription, and a trainer that listens.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Spacer()
                if let message = error ?? model.backendError {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 32)
                }
                Button {
                    Task { await signIn() }
                } label: {
                    // The hidden title keeps the button from resizing; .regular stops the spinner inheriting .large.
                    Text("Sign in with Intervals.icu")
                        .font(.headline)
                        .opacity(busy ? 0 : 1)
                        .overlay { if busy { ProgressView().controlSize(.regular) } }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy)
                .padding(.horizontal, 24)
                Text("Cadencia keeps your plan and the coach's notes on its server in the EU. The coach's AI runs on this phone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)
            }
        }
    }

    private func signIn() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            try await model.signIn()
        } catch BackendSignIn.Failure.cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

#Preview {
    SignInView().environment(PreviewData.model(signedIn: false))
}
