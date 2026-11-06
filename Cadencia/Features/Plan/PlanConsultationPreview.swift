#if DEBUG
import SwiftUI
import CadenciaCore

/// A Simulator fixture with no live credentials or calendar writes.
struct PlanConsultationPreview: View {
    @State private var model = makeModel()
    @State private var presenting = true
    private let showRecording = !ProcessInfo.processInfo.arguments.contains("--cadencia-consultation-idle")

    var body: some View {
        PlanView()
            .fullScreenCover(isPresented: $presenting) {
                CreatePlanView(previewTranscript: showRecording ? String(localized: "I’d like to combine cycling with CrossFit.") : nil)
            }
            .environment(model)
    }

    @MainActor private static func makeModel() -> AppModel {
        var state = PreviewData.state
        state.athlete?.weightKg = nil
        state.athlete?.ftp = nil
        state.athlete?.indoorFTP = nil
        state.acceptedFTP = nil
        state.plan = nil
        state.today = nil
        state.settings.llmEnabled = true
        let empty = ProcessInfo.processInfo.arguments.contains("--cadencia-consultation-empty")
        if empty { state.activities = [] }
        var session = PlanConsultation.Session(startedOn: Day(Date()))
        session.reply = .init(
            review: empty ? String(localized: "Let’s get to know your riding.") :
                String(localized: "Your recent rides give us a starting point. We can fill in the missing details as we talk."),
            question: String(localized: "What other training would you like to include?"), topic: .otherTraining)
        let athlete = state.athlete.flatMap { CadenciaAPI.AthleteId(rawValue: $0.id) } ?? CadenciaAPI.AthleteId(rawValue: "i12345")!
        state.consultation = .init(id: BackendID.newConsultation(athlete: athlete), startedOn: session.startedOn,
                                   view: .init(.init(stage: .open, turns: [.init(role: .coach, text: try! .init(fitting: session.reply!.question))])))
        let transport = ConsultationPreviewTransport()
        let coach = LLMCoach(transport: transport, endpoint: URL(string: "https://example.invalid/chat/completions")!, apiKey: "preview")
        let backend = CoachBackend(api: CadenciaAPI(baseURL: URL(string: "https://cadencia.invalid")!, transport: transport, sessionToken: "preview"),
                                   athleteId: athlete, pause: { _ in })
        let model = AppModel(state: state, credential: .apiKey("preview"), store: .temporary(), keychain: KeychainStore(service: "preview.consultation"),
                             transport: transport, coachOverride: coach, backendOverride: backend)
        model.previewConsultationReply(session.reply!)
        return model
    }
}

private struct ConsultationPreviewTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        // Cadencia's backend: every command is recorded, and the consultation stays open.
        if request.url.path.hasPrefix("/v1/") {
            if request.method == .post { return HTTPResponse(status: 200, body: Data(#"{"reply":null,"stream":"preview","version":1}"#.utf8)) }
            let open = #"{"stage":"open","turns":[],"draft":null,"planId":null,"refusal":null}"#
            return HTTPResponse(status: 200, body: Data((request.url.path.hasPrefix("/v1/ConsultationView/") ? open : "null").utf8))
        }
        guard request.url.path.hasSuffix("chat/completions") else { throw HTTPError.invalidResponse }
        let today = Day(Date())
        let reply = PlanConsultation.Reply(
            review: String(localized: "Your plan makes room for CrossFit and keeps your long ride on Sunday."),
            question: String(localized: "Would you like to review the plan?"), topic: .review,
            coveredTopics: [.goal, .availability, .otherTraining, .timeAway],
            draft: .init(title: String(localized: "Stronger on long rides"), goal: .durability, startDay: today, endDay: today.adding(days: 27),
                details: .init(objective: String(localized: "Finish Sunday rides feeling stronger."),
                    rationale: String(localized: "An easy ride after CrossFit leaves room for your longer Sunday ride."),
                    weeklyRides: [.init(weekday: 5, minutes: 45, kind: .endurance), .init(weekday: 1, minutes: 120, kind: .longRide)],
                    otherTraining: [.init(name: "CrossFit", weekdays: [4], minutes: 45, intensity: .hard)],
                    timeAway: [.init(start: today.adding(days: 14), end: today.adding(days: 20), reason: String(localized: "Vacation"))]),
                phases: [.init(focus: .base, startWeek: 1, endWeek: 3, summary: String(localized: "Build a steady routine.")),
                         .init(focus: .recover, startWeek: 4, endWeek: 4, summary: String(localized: "Ease off and review how the block felt."))]))
        let content = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        return HTTPResponse(status: 200, body: response)
    }
}
#endif
