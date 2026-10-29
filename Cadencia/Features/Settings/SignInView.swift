import SwiftUI
import CadenciaCore

/// First screen when no Intervals.icu credential is stored. OAuth is the primary path when the app has a
/// registered client id; the API key path always works and is where the design puts it: under "Advanced".
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @State private var showAPIKey = false
    @State private var busy = false
    @State private var error: String?

    private var oauthAvailable: Bool { AppConfig.intervalsOAuth != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "figure.indoor.cycle")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.tint)
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
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 32)
                }
                VStack(spacing: 12) {
                    if oauthAvailable {
                        Button {
                            Task { await signInWithOAuth() }
                        } label: {
                            HStack {
                                if busy { ProgressView().tint(.white) }
                                Text("Connect Intervals.icu")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(busy)
                        Button("Use an API key instead") { showAPIKey = true }
                            .font(.footnote)
                    } else {
                        Button {
                            showAPIKey = true
                        } label: {
                            Text("Connect with an API key").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                .padding(.horizontal, 24)
                Text("Cadencia stores your credential only in this phone's Keychain and talks to Intervals.icu directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 16)
            }
            .sheet(isPresented: $showAPIKey) { APIKeyView() }
        }
    }

    private func signInWithOAuth() async {
        busy = true
        defer { busy = false }
        error = nil
        do { try await model.signInWithOAuth() } catch { self.error = Self.describe(error) }
    }

    static func describe(_ error: Error) -> String {
        if let http = error as? HTTPError, http.isAuthFailure { return String(localized: "Intervals.icu did not accept that credential.") }
        return error.localizedDescription
    }
}

struct APIKeyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API key", text: $key)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit { Task { await connect() } }
                } header: {
                    Text("Intervals.icu API key")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("In Intervals.icu open Settings, scroll to Developer Settings and copy the API key. The key gives full access to your account; it never leaves this phone except to call intervals.icu.")
                        Link("Open Intervals.icu settings", destination: AppConfig.intervalsSettingsURL)
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("API key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Connect") { Task { await connect() } }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty) }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func connect() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            try await model.signIn(apiKey: key)
            dismiss()
        } catch {
            self.error = SignInView.describe(error)
        }
    }
}

#Preview {
    SignInView().environment(PreviewData.model(signedIn: false))
}
