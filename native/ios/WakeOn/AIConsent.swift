import SwiftUI

/// Permission to send the user's voice to OpenAI during calls (App Review Guideline 5.1.2(i):
/// disclose sharing with third-party AI and get explicit permission first). Asked once before
/// the first call; withdrawn from Settings › Privacy, after which the next call asks again.
enum AIConsent {
    static let key = "consent.openai.v1"
    static let privacyPolicy = URL(string: "https://github.com/kamikaz1k/wake-on/blob/master/docs/privacy.md")!

    static var given: Bool { UserDefaults.standard.bool(forKey: key) }
    static func set(_ value: Bool) { UserDefaults.standard.set(value, forKey: key) }

    /// Shown when a call can't start for lack of permission and the sheet can't be shown
    /// (the Action Button or "Hey Lobby" with the app in the background).
    static let backgroundMessage = "Open Pixie and agree to sending your voice to OpenAI before your first call."
}

/// The one-time permission sheet. Standard components only.
struct AIConsentView: View {
    let agree: () -> Void
    let decline: () -> Void

    var body: some View {
        NavigationStack { AIConsentPage(agree: agree, decline: decline) }
    }
}

/// The permission text and buttons, as a sheet (AIConsentView) or an onboarding page.
struct AIConsentPage: View {
    let agree: () -> Void
    let decline: () -> Void

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Talking to Lobby uses OpenAI")
                        .font(.title2.bold())
                    Text("During a call, Pixie sends your voice to OpenAI so Lobby can understand and answer you, along with anything you ask Lobby to look at, like a web page in Pixie’s browser.")
                    Text("This happens only while a call is on. “Hey Lobby” listening runs on your iPhone and sends nothing until a call starts. Your chat history stays on your iPhone.")
                    Text("OpenAI handles this data under its API policies. You can turn this off any time in Settings › Privacy.")
                        .foregroundStyle(.secondary)
                    Link("Privacy Policy", destination: AIConsent.privacyPolicy)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button(action: agree) {
                        Text("Agree and Continue").frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("consent-agree")
                    Button("Not Now", action: decline)
                        .accessibilityIdentifier("consent-decline")
                }
                .padding()
                .background(.bar)
            }
            .navigationBarTitleDisplayMode(.inline)
    }
}
