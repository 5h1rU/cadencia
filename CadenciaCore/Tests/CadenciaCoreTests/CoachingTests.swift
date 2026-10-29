import XCTest
@testable import CadenciaCore

final class ReadinessEngineTests: XCTestCase {
    let engine = ReadinessEngine()
    let today = Day(year: 2026, month: 10, day: 28)

    func history(hrv: Double = 65, sleep: Int = 7 * 3600 + 30 * 60, rhr: Int = 50, days: Int = 28) -> [WellnessDay] {
        (1...days).map { i in
            // Small deterministic wobble so the SD is not zero.
            let wobble = Double(i % 5) - 2
            return WellnessDay(day: today.adding(days: -i), hrvMs: hrv + wobble * 2, restingHR: rhr + Int(wobble), sleepSeconds: sleep + Int(wobble) * 600, ctl: 60, atl: 60)
        }
    }

    func testLowHRVShortSleepAndDeepFatigueCallsForEasyDay() {
        let today = WellnessDay(day: today, hrvMs: 48, restingHR: 54, sleepSeconds: 6 * 3600 + 12 * 60, ctl: 62, atl: 78)
        let r = engine.evaluate(today: today, history: history())
        XCTAssertEqual(r.level, .easy, "score \(r.score) signals \(r.signals)")
        XCTAssertEqual(r.signals.first { $0.name == "hrv" }?.verdict, .below)
        XCTAssertEqual(r.signals.first { $0.name == "sleep" }?.verdict, .below)
        XCTAssertTrue(r.missingData.isEmpty)
    }

    func testTypicalDayIsNormal() {
        let today = WellnessDay(day: today, hrvMs: 66, restingHR: 50, sleepSeconds: 7 * 3600 + 20 * 60, ctl: 60, atl: 62)
        let r = engine.evaluate(today: today, history: history())
        XCTAssertEqual(r.level, .normal, "score \(r.score)")
    }

    func testHighHRVPositiveFormIsStrong() {
        let today = WellnessDay(day: today, hrvMs: 78, restingHR: 47, sleepSeconds: 8 * 3600, ctl: 60, atl: 50)
        let r = engine.evaluate(today: today, history: history())
        XCTAssertEqual(r.level, .strong, "score \(r.score)")
    }

    func testHeavyLegsDowngradesAnOtherwiseNormalDay() {
        let today = WellnessDay(day: today, hrvMs: 66, restingHR: 50, sleepSeconds: 7 * 3600 + 20 * 60, ctl: 60, atl: 70)
        let normal = engine.evaluate(today: today, history: history())
        let heavy = engine.evaluate(today: today, history: history(), feedback: SubjectiveFeedback(day: self.today, legs: .heavy))
        XCTAssertLessThan(heavy.score, normal.score)
        XCTAssertEqual(heavy.level, .easy, "score \(heavy.score)")
    }

    func testFewerThanSevenBaselineDaysMeansSignalsAreMissingAndNeverStrong() {
        let today = WellnessDay(day: today, hrvMs: 90, restingHR: 45, sleepSeconds: 9 * 3600, ctl: 60, atl: 40)
        let r = engine.evaluate(today: today, history: history(days: 4))
        XCTAssertEqual(Set(r.missingData), ["hrv", "sleep", "restingHR"])
        XCTAssertNotEqual(r.level, .strong)
        XCTAssertFalse(r.isSufficientlyInformed == false && r.signals.filter { $0.verdict != .missing }.count >= 2)
    }

    func testBaselineIgnoresTodayAndFutureDays() {
        // A wildly different "future" day must not shift the baseline.
        var hist = history()
        hist.append(WellnessDay(day: today.adding(days: 1), hrvMs: 500, restingHR: 20, sleepSeconds: 20 * 3600))
        let today = WellnessDay(day: today, hrvMs: 66, restingHR: 50, sleepSeconds: 7 * 3600 + 20 * 60, ctl: 60, atl: 62)
        let r = engine.evaluate(today: today, history: hist)
        XCTAssertEqual(r.signals.first { $0.name == "hrv" }?.verdict, .typical)
    }
}

final class FTPEstimatorTests: XCTestCase {
    let e = FTPEstimator()

    func testUsesStrongestOfTheThreeModelsAndReportsBasis() {
        // P20 = 260 → 247. P60 = 250. CP from P3 = 340, P12 = 270 → (270·720 − 340·180)/540 = 246.7
        let curve = [PowerCurvePoint(seconds: 180, watts: 340), .init(seconds: 720, watts: 270), .init(seconds: 1200, watts: 260), .init(seconds: 3600, watts: 250)]
        let est = e.estimate(curve: curve, sustainedEfforts: 3)!
        XCTAssertEqual(est.watts, 250)
        XCTAssertEqual(est.basis, "best 60 min")
        XCTAssertEqual(est.confidence, .moderate)
    }

    func testNoUsableDurationsMeansNoEstimate() {
        XCTAssertNil(e.estimate(curve: [PowerCurvePoint(seconds: 5, watts: 900)], sustainedEfforts: 0))
    }

    func testProposalIgnoresTinyIncreasesAndLowConfidence() {
        XCTAssertNil(e.proposal(current: 240, estimate: FTPEstimate(watts: 243, confidence: .high, sustainedEfforts: 5, basis: "", windowDays: 42)))
        XCTAssertEqual(e.proposal(current: 240, estimate: FTPEstimate(watts: 248, confidence: .moderate, sustainedEfforts: 3, basis: "", windowDays: 42)), 248)
        XCTAssertNil(e.proposal(current: 240, estimate: FTPEstimate(watts: 260, confidence: .low, sustainedEfforts: 1, basis: "", windowDays: 42)))
        XCTAssertNil(e.proposal(current: 240, estimate: FTPEstimate(watts: 232, confidence: .high, sustainedEfforts: 5, basis: "", windowDays: 42), recentEFTP: 220), "−3 % is inside the hysteresis")
    }

    func testDecreaseNeedsIntervalsEFTPToAgree() {
        let low = FTPEstimate(watts: 226, confidence: .high, sustainedEfforts: 5, basis: "", windowDays: 42)
        XCTAssertNil(e.proposal(current: 240, estimate: low), "a quiet six weeks is not evidence of a lower FTP")
        XCTAssertNil(e.proposal(current: 240, estimate: low, recentEFTP: 236), "eFTP within 5 % keeps the working value")
        XCTAssertEqual(e.proposal(current: 240, estimate: low, recentEFTP: 225), 226)
    }
}

final class WorkoutOutlineTests: XCTestCase {
    private func steady(_ name: String, minutes: Double, _ intensity: Double) -> WorkoutStep {
        WorkoutStep(name: name, duration: minutes * 60, intensity: intensity)
    }

    func testIntervalsCollapseIntoOneSetRow() {
        // Warm-up, (Threshold 10' @ 98 %, Recovery 5' @ 50 %) × 4, Cool-down: a coach-shaped 75-minute session.
        var steps = [WorkoutStep(name: "Warm-up", duration: 15 * 60, startIntensity: 0.45, endIntensity: 0.65)]
        for n in 1...4 {
            steps.append(steady("Threshold \(n)", minutes: 10, 0.98))
            steps.append(steady("Recovery \(n)", minutes: 5, 0.50))
        }
        steps.append(steady("Cool-down", minutes: 10, 0.45))
        let w = Workout(name: "Threshold", kind: .threshold, steps: steps)
        let rows = w.outline
        XCTAssertEqual(rows.map(\.title), ["Warm-up", "Threshold", "Cool-down"])
        let set = rows[1]
        XCTAssertEqual(set.repeats, 4)
        XCTAssertEqual(set.rest?.name, "Recovery 1")
        XCTAssertEqual(set.totalDuration, 60 * 60, accuracy: 1, "the set row owns every work and recovery step between warm-up and cool-down")
        XCTAssertEqual(rows.reduce(0) { $0 + $1.totalDuration }, w.totalDuration, accuracy: 1)
    }

    func testSteadySessionKeepsThreeRows() {
        let w = Workout(name: "Easy endurance", kind: .endurance, steps: [
            WorkoutStep(name: "Warm-up", duration: 10 * 60, startIntensity: 0.45, endIntensity: 0.6),
            steady("Steady endurance", minutes: 45, 0.65),
            steady("Cool-down", minutes: 5, 0.45),
        ])
        XCTAssertEqual(w.outline.map(\.repeats), [1, 1, 1])
        XCTAssertEqual(w.outline[1].title, "Steady endurance")
    }

    func testOpenersWithTrailingEasyAreOneSet() {
        // Warm-up, (Opener 1' @ 110 %, Easy 2' @ 50 %) × 3, Cool-down → the trailing Easy belongs to the set.
        var steps = [steady("Warm-up", minutes: 10, 0.5)]
        for n in 1...3 {
            steps.append(steady("Opener \(n)", minutes: 1, 1.10))
            steps.append(steady("Easy \(n)", minutes: 2, 0.50))
        }
        steps.append(steady("Cool-down", minutes: 5, 0.45))
        let w = Workout(name: "Opener", kind: .openerActivation, steps: steps)
        XCTAssertEqual(w.outline.map(\.title), ["Warm-up", "Opener", "Cool-down"])
        XCTAssertEqual(w.outline[1].repeats, 3)
        XCTAssertEqual(w.outline[1].totalDuration, 9 * 60, accuracy: 1)
    }
}

final class PlanBuilderTests: XCTestCase {
    // 2026-11-02 is a Monday; 2027-02-21 is a Sunday.
    let start = Day(year: 2026, month: 11, day: 2)
    let eventDay = Day(year: 2027, month: 2, day: 21)

    func testEventPlanHasSixteenWeeksPhasesAndTheEventOnItsDay() {
        let event = TrainingEvent(name: "Gran fondo", day: eventDay, distanceKm: 200, priority: .a, objective: "finish strong", isRace: true)
        let plan = PlanBuilder().build(.init(goal: .event, startDay: start, endDay: eventDay, event: event, availability: .typical))
        XCTAssertEqual(plan.weekCount, 16)
        XCTAssertEqual(plan.phases.map(\.focus), [.base, .build, .peak, .taper])
        XCTAssertEqual(plan.phases.last?.startWeek, 16)
        let race = plan.sessions.first { $0.day == eventDay }
        XCTAssertEqual(race?.kind, .race)
        XCTAssertTrue(race?.isPriority == true)
        var groupRide = event
        groupRide.isRace = false
        let plan2 = PlanBuilder().build(.init(goal: .event, startDay: start, endDay: eventDay, event: groupRide, availability: .typical))
        XCTAssertEqual(plan2.sessions.first { $0.day == eventDay }?.kind, .groupRide, "priority is independent of race vs group ride")
        XCTAssertTrue(plan2.sessions.first { $0.day == eventDay }?.isPriority == true)
        XCTAssertEqual(plan.sessions.first { $0.day == eventDay.adding(days: -1) }?.kind, .openerActivation)
        XCTAssertEqual(plan.weekNumber(of: Day(year: 2026, month: 11, day: 4)), 1)
        XCTAssertEqual(plan.phase(for: eventDay)?.focus, .taper)
    }

    func testOnlyAvailableDaysGetSessionsAndLongRideLandsOnItsWeekday() {
        let plan = PlanBuilder().build(.init(goal: .climbing, startDay: start, endDay: start.adding(days: 55), availability: .typical))
        XCTAssertEqual(plan.weekCount, 8)
        XCTAssertTrue(plan.sessions.allSatisfy { Availability.typical.minutesByWeekday[$0.day.weekday()] != nil })
        XCTAssertFalse(plan.sessions.contains { $0.day.weekday() == 6 }, "Friday is not available in .typical")
        let sundays = plan.sessions.filter { $0.day.weekday() == 1 }
        XCTAssertEqual(sundays.count, 8)
        XCTAssertTrue(sundays.allSatisfy { $0.kind == .longRide })
        XCTAssertTrue(plan.sessions.allSatisfy { $0.status == .provisional }, "future sessions are intentions, not generated workouts")
    }

    func testRecoveryWeekHasNoHardSessions() {
        let plan = PlanBuilder().build(.init(goal: .ftp, startDay: start, endDay: start.adding(days: 55), availability: .typical))
        let week4 = plan.sessions.filter { plan.weekNumber(of: $0.day) == 4 }
        XCTAssertFalse(week4.isEmpty)
        XCTAssertFalse(week4.contains { $0.kind.isHard })
        let week3 = plan.sessions.filter { plan.weekNumber(of: $0.day) == 3 }
        XCTAssertTrue(week3.contains { $0.kind.isHard })
    }
}

final class WeekReviserTests: XCTestCase {
    let monday = Day(year: 2026, month: 10, day: 26)

    func makePlan() -> TrainingPlan {
        PlanBuilder().build(.init(goal: .endurance, startDay: monday, endDay: monday.adding(days: 27), availability: .typical))
    }

    func testEventOnSundayPinsPriorityAndSoftensTheTwoDaysBefore() {
        let today = monday.adding(days: 2) // Wednesday
        let sunday = monday.adding(days: 6)
        let intent = CoachIntent(event: TrainingEvent(name: "Group ride 200 km", day: sunday, distanceKm: 200, priority: .a, objective: "arrive fresh"),
                                 constraints: [.init(day: monday.adding(days: 3), maxMinutes: 40)])
        let rev = WeekReviser().apply(intent, to: makePlan(), today: today)
        let week = rev.plan.sessions(inWeekOf: today)
        XCTAssertEqual(week.first { $0.day == sunday }?.kind, .groupRide)
        XCTAssertEqual(week.first { $0.day == sunday }?.isPriority, true)
        XCTAssertEqual(week.first { $0.day == sunday.adding(days: -1) }?.kind, .openerActivation)
        XCTAssertEqual(week.first { $0.day == monday.adding(days: 3) }?.targetMinutes, 40)
        XCTAssertTrue(rev.changed.contains { $0.day == sunday })
        // Thursday is 40 min and was a hard day in .typical availability? Either way it must not exceed the cap.
        XCTAssertTrue(week.filter { $0.day == monday.adding(days: 3) }.allSatisfy { $0.targetMinutes <= 40 })
    }

    func testConstraintsInThePastAreIgnored() {
        let today = monday.adding(days: 3)
        let intent = CoachIntent(constraints: [.init(day: monday.adding(days: 1), unavailable: true)])
        let rev = WeekReviser().apply(intent, to: makePlan(), today: today)
        XCTAssertTrue(rev.changed.isEmpty)
        XCTAssertEqual(rev.plan.sessions.first { $0.day == monday.adding(days: 1) }?.status, .provisional)
    }
}

final class ChatGPTPlanCoachTests: XCTestCase {
    let context = CoachContext(today: Day(year: 2026, month: 10, day: 28))

    func testLLMWireMapping() {
        let wire = LLMCoach.Wire(event: .init(name: "Race", day: "2026-11-01", distanceKm: 120, priority: "b", objective: "finish strong"),
                                 constraints: [.init(day: "2026-10-30", maxMinutes: nil, unavailable: true), .init(day: "bad", maxMinutes: 30, unavailable: nil)],
                                 feeling: "fresh", goal: "climbing", reply: "ok", needsClarification: nil)
        let intent = LLMCoach.intent(from: wire)
        XCTAssertEqual(intent.event?.priority, .b)
        XCTAssertEqual(intent.constraints.count, 1, "invalid dates are dropped, never guessed")
        XCTAssertEqual(intent.feeling, .fresh)
        XCTAssertEqual(intent.goal, .climbing)
    }

    func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testFirstRegistrationUsesDynamicClientAndAgentName() {
        let a = ChatGPTAuth.Attempt(clientID: nil, hostID: "urn:uuid:h1", redirectURI: ChatGPTAuth.redirectURI(port: 1455))
        let q = query(ChatGPTAuth().authorizationURL(a))
        XCTAssertEqual(q["client_id"], "dynamic_agent_client")
        XCTAssertEqual(q["agent_name_hint"], "Cadencia")
        XCTAssertEqual(q["ext_agent_host_id"], "urn:uuid:h1")
        XCTAssertEqual(q["redirect_uri"], "http://127.0.0.1:1455/auth/callback")
        XCTAssertEqual(q["scope"], "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        XCTAssertEqual(q["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"], a.pkce.challenge)
        XCTAssertNil(q["id_token_hint"])
    }

    func testReauthorizationUsesIssuedClientWithoutAgentName() {
        let a = ChatGPTAuth.Attempt(clientID: "oaiapp_1", hostID: "urn:uuid:h1", redirectURI: ChatGPTAuth.redirectURI(port: 50000), idTokenHint: "x.y.z", loginHint: "a@b.c")
        let q = query(ChatGPTAuth().authorizationURL(a))
        XCTAssertEqual(q["client_id"], "oaiapp_1")
        XCTAssertNil(q["agent_name_hint"])
        XCTAssertEqual(q["id_token_hint"], "x.y.z")
        XCTAssertEqual(q["login_hint"], "a@b.c")
    }

    func testCallbackRequiresIssuedClientIDOnRegistrationAndRejectsMismatch() throws {
        let auth = ChatGPTAuth()
        let fresh = ChatGPTAuth.Attempt(clientID: nil, hostID: "h", redirectURI: ChatGPTAuth.redirectURI(port: 1), state: "s1")
        let ok = try auth.parseCallback(URL(string: "http://127.0.0.1:1/auth/callback?code=c&state=s1&client_id=oaiapp_9")!, for: fresh)
        XCTAssertEqual(ok, .init(code: "c", clientID: "oaiapp_9"))
        XCTAssertThrowsError(try auth.parseCallback(URL(string: "http://127.0.0.1:1/auth/callback?code=c&state=s1")!, for: fresh)) {
            XCTAssertEqual($0 as? ChatGPTAuth.Failure, .missingClientID)
        }
        XCTAssertThrowsError(try auth.parseCallback(URL(string: "http://127.0.0.1:1/auth/callback?code=c&state=other&client_id=oaiapp_9")!, for: fresh)) {
            XCTAssertEqual($0 as? ChatGPTAuth.Failure, .stateMismatch)
        }
        XCTAssertThrowsError(try auth.parseCallback(URL(string: "http://127.0.0.1:1/auth/callback?error=access_denied&state=s1")!, for: fresh)) {
            XCTAssertEqual($0 as? ChatGPTAuth.Failure, .accessDenied)
        }
        let saved = ChatGPTAuth.Attempt(clientID: "oaiapp_1", hostID: "h", redirectURI: ChatGPTAuth.redirectURI(port: 1), state: "s2")
        XCTAssertEqual(try auth.parseCallback(URL(string: "http://127.0.0.1:1/auth/callback?code=c&state=s2")!, for: saved).clientID, "oaiapp_1")
        XCTAssertThrowsError(try auth.parseCallback(URL(string: "http://127.0.0.1:1/auth/callback?code=c&state=s2&client_id=oaiapp_2")!, for: saved)) {
            XCTAssertEqual($0 as? ChatGPTAuth.Failure, .clientIDMismatch)
        }
    }

    func jwt(_ claims: [String: Any]) -> String {
        func b64(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }
        return b64(Data(#"{"alg":"RS256"}"#.utf8)) + "." + b64(try! JSONSerialization.data(withJSONObject: claims)) + ".sig"
    }

    func testExchangeSendsPKCEAndResourceAndValidatesNonce() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let id = jwt(["iss": "https://auth.openai.com", "aud": "oaiapp_9", "sub": "user-1", "email": "f@x.io", "nonce": "n1", "exp": now.timeIntervalSince1970 + 600])
        let body = #"{"access_token":"at","refresh_token":"rt","id_token":"\#(id)","token_type":"Bearer","expires_in":3600,"scope":"openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"}"#
        let t = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(body.utf8))])
        let auth = ChatGPTAuth()
        let attempt = ChatGPTAuth.Attempt(clientID: nil, hostID: "urn:uuid:h", redirectURI: ChatGPTAuth.redirectURI(port: 1455), state: "s", nonce: "n1")
        let callback = ChatGPTAuth.Callback(code: "code1", clientID: "oaiapp_9")
        let token = try await auth.exchange(callback, attempt: attempt, transport: t)
        let form = String(decoding: t.requests[0].body!, as: UTF8.self)
        XCTAssertEqual(t.requests[0].url, ChatGPTAuth.tokenURL)
        XCTAssertTrue(form.contains("grant_type=authorization_code"))
        XCTAssertTrue(form.contains("client_id=oaiapp_9"), "the issued id, never dynamic_agent_client")
        XCTAssertTrue(form.contains("code_verifier=\(attempt.pkce.verifier)"))
        XCTAssertTrue(form.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback"))
        XCTAssertTrue(form.contains("resource=https%3A%2F%2Fapi.openai.com%2Fv1"))
        XCTAssertFalse(form.contains("client_secret"))

        let credential = try auth.credential(from: token, callback: callback, attempt: attempt, now: now)
        XCTAssertEqual(credential.subject, "user-1")
        XCTAssertEqual(credential.email, "f@x.io")
        XCTAssertTrue(credential.planUsageEnabled)
        XCTAssertEqual(credential.expiresAt, now.addingTimeInterval(3600))

        var wrongNonce = attempt; wrongNonce.nonce = "n2"
        XCTAssertThrowsError(try auth.credential(from: token, callback: callback, attempt: wrongNonce, now: now))
        XCTAssertThrowsError(try auth.credential(from: token, callback: .init(code: "c", clientID: "oaiapp_other"), attempt: attempt, now: now))
    }

    func testIdentityWithoutPlanScopeIsNotPlanUsage() {
        let c = ChatGPTCredential(clientID: "x", hostID: "h", subject: "s", email: nil, idToken: "", accessToken: "a", refreshToken: nil,
                                  expiresAt: Date(), scopes: ["openid", "email", "profile"])
        XCTAssertFalse(c.planUsageEnabled)
    }

    func testRefreshRotatesTokensAndTerminalErrorsAreTyped() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let c = ChatGPTCredential(clientID: "oaiapp_9", hostID: "h", subject: "s", email: nil, idToken: "id", accessToken: "old", refreshToken: "r1",
                                  expiresAt: now, scopes: ["chatgpt.tokens.use.direct"])
        let t = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(#"{"access_token":"new","refresh_token":"r2","expires_in":3600}"#.utf8))])
        let next = try await ChatGPTAuth().refresh(c, transport: t, now: now)
        let form = String(decoding: t.requests[0].body!, as: UTF8.self)
        XCTAssertTrue(form.contains("grant_type=refresh_token") && form.contains("refresh_token=r1") && form.contains("client_id=oaiapp_9"))
        XCTAssertFalse(form.contains("scope="), "omit scope to retain the grant")
        XCTAssertEqual(next.accessToken, "new")
        XCTAssertEqual(next.refreshToken, "r2")
        XCTAssertEqual(next.scopes, ["chatgpt.tokens.use.direct"], "scopes kept when the reply omits them")
        XCTAssertFalse(next.needsRefresh(now: now))
        XCTAssertTrue(next.needsRefresh(now: now.addingTimeInterval(3541)))

        let dead = FakeTransport(responses: [HTTPResponse(status: 400, body: Data(#"{"error":"refresh_token_reused"}"#.utf8))])
        do {
            _ = try await ChatGPTAuth().refresh(c, transport: dead, now: now)
            XCTFail("expected a terminal refresh error")
        } catch ChatGPTAuth.Failure.refreshTokenUnusable {
        }
    }

    func testPlanRequestUsesResponsesAPIContract() throws {
        let coach = LLMCoach(transport: FakeTransport(), backend: .chatGPTPlan(accessToken: "tok"), model: "gpt-5.6-sol")
        let req = try coach.request(utterance: "hola", context: context)
        XCTAssertEqual(req.url, LLMCoach.responsesURL)
        XCTAssertEqual(req.headers["Authorization"], "Bearer tok")
        let body = try JSONSerialization.jsonObject(with: req.body!) as! [String: Any]
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNotNil(body["instructions"])
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["messages"], "chat-completions shape must not leak into the Responses route")
        let input = body["input"] as! [[String: Any]]
        XCTAssertEqual(input.map { $0["role"] as? String }, ["user"], "no system items: the route rejects them")
    }

    func testResponsesStreamIsParsedThroughCompletion() async throws {
        let sse = """
        event: response.created
        data: {"type":"response.created","response":{"id":"r1"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"{\\"reply\\":\\"Vale\\","}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"\\"feeling\\":\\"heavy\\"}"}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"r1","output":[{"type":"message","content":[{"type":"output_text","text":"{\\"reply\\":\\"Vale\\",\\"feeling\\":\\"heavy\\"}"}]}]}}

        """
        let t = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(sse.utf8))])
        let coach = LLMCoach(transport: t, backend: .chatGPTPlan(accessToken: "tok"))
        let intent = try await coach.interpret("piernas pesadas", context: context)
        XCTAssertEqual(intent.reply, "Vale")
        XCTAssertEqual(intent.feeling, .heavy)
    }

    func testUsageLimitSurfacesInsteadOfSilentFallback() async {
        let failed = "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}\n"
        let streamed = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(failed.utf8))])
        do {
            _ = try await LLMCoach(transport: streamed, backend: .chatGPTPlan(accessToken: "tok")).interpret("x", context: context)
            XCTFail("expected usage limit")
        } catch { XCTAssertEqual(error as? LLMCoachError, .usageLimitReached) }

        let rejected = FakeTransport(responses: [HTTPResponse(status: 429, body: Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#.utf8))])
        do {
            _ = try await LLMCoach(transport: rejected, backend: .chatGPTPlan(accessToken: "tok")).interpret("x", context: context)
            XCTFail("expected usage limit")
        } catch { XCTAssertEqual(error as? LLMCoachError, .usageLimitReached) }

        // An incomplete stream (no response.completed) is an error too: there is no on-device fallback.
        let partial = FakeTransport(responses: [HTTPResponse(status: 200, body: Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"{\"}\n".utf8))])
        do {
            _ = try await LLMCoach(transport: partial, backend: .chatGPTPlan(accessToken: "tok")).interpret("me siento fresco", context: context)
            XCTFail("expected an error")
        } catch { XCTAssertEqual(error as? LLMCoach.CompletionError, .emptyResponse) }
    }

    func testModelCatalogShapes() async throws {
        let plan = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(#"{"models":[{"slug":"gpt-6-astra","display_name":"GPT-6 Astra","visibility":"list"},{"slug":"hidden","display_name":"H","visibility":"hidden"}]}"#.utf8))])
        let a = try await LLMCoach(transport: plan, backend: .chatGPTPlan(accessToken: "t")).listModels()
        XCTAssertEqual(a.map(\.id), ["gpt-6-astra"])
        XCTAssertEqual(a.first?.name, "GPT-6 Astra")
        let api = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(#"{"data":[{"id":"gpt-5.6-sol"}]}"#.utf8))])
        let b = try await LLMCoach(transport: api, backend: .apiKey(endpoint: URL(string: "https://x")!, key: "k")).listModels()
        XCTAssertEqual(b.map(\.id), ["gpt-5.6-sol"])
    }
}

final class AICoachTests: XCTestCase {
    let today = Day(year: 2026, month: 10, day: 29)
    let baseline = Readiness(level: .normal, score: 58,
                             signals: [.init(name: "hrv", verdict: .typical, value: 61, baseline: 55...68, weight: 0)],
                             missingData: ["sleep"], summary: "Within usual range.")

    func parse(_ json: String, available: Int? = nil) throws -> DailyPrescription {
        try DailyPrescription.parse(Data(json.utf8), measured: .init(baseline), today: today, availableMinutes: available, model: "m", now: Date(timeIntervalSince1970: 0))
    }

    func testValidAnswerBecomesTrainerReadyWorkoutAndKeepsBaselineSignals() throws {
        let p = try parse("""
        {"readiness":{"level":"strong","score":81,"headline":"Día para apretar","rationale":"HRV 66 ms, dormiste 8 h."},
         "workout":{"name":"2×20 umbral","kind":"threshold","ceiling":1.05,"rationale":"Estás fresco.",
                    "steps":[{"name":"Calentamiento","minutes":10,"from":0.5,"to":0.75},
                             {"name":"Umbral","minutes":20,"intensity":0.98,"cadence":90},
                             {"name":"Recuperación","minutes":5,"intensity":0.55},
                             {"name":"Umbral","minutes":20,"intensity":0.98},
                             {"name":"Vuelta a la calma","minutes":5,"from":0.6,"to":0.4}]},
         "week":[{"day":"2026-10-29","kind":"threshold","minutes":60,"title":"2×20","note":"hoy"},
                 {"day":"2026-10-30","kind":"recovery","minutes":45,"title":"Suave"},
                 {"day":"2026-11-05","kind":"endurance","minutes":90,"title":"Z2"},
                 {"day":"2026-11-06","kind":"rest","minutes":0,"title":"Fuera de la semana"},
                 {"day":"2026-10-20","kind":"rest","minutes":0,"title":"Pasado"}],
         "coachNote":"Buen momento para construir.","flags":["ftp_review"]}
        """)
        XCTAssertEqual(p.readiness.level, .strong)
        XCTAssertEqual(p.readiness.score, 81)
        XCTAssertEqual(p.readiness.summary, "Día para apretar HRV 66 ms, dormiste 8 h.")
        XCTAssertEqual(p.readiness.signals, baseline.signals, "the model does not rewrite the measured signals")
        XCTAssertEqual(p.readiness.missingData, ["sleep"])
        XCTAssertEqual(p.workout.kind, .threshold)
        XCTAssertEqual(p.workout.steps.count, 5)
        XCTAssertEqual(p.workout.steps[0].startIntensity, 0.5)
        XCTAssertEqual(p.workout.steps[0].endIntensity, 0.75)
        XCTAssertTrue(p.workout.steps[0].isRamp)
        XCTAssertEqual(p.workout.steps[1].duration, 1200)
        XCTAssertEqual(p.workout.steps[1].cadenceRPM, 90)
        XCTAssertEqual(p.workout.totalDuration, 3600)
        XCTAssertEqual(p.workout.intensityCeiling, 1.05)
        XCTAssertEqual(p.week.map(\.day.iso), ["2026-10-29", "2026-10-30", "2026-11-05"], "outlook is clipped to today…+7 days")
        XCTAssertEqual(p.coachNote, "Buen momento para construir.")
        XCTAssertEqual(p.flags, ["ftp_review"])
        XCTAssertEqual(p.model, "m")
    }

    func testRestDayHasNoStepsAndZeroCeiling() throws {
        let p = try parse(#"{"readiness":{"level":"rest"},"workout":{"name":"Descanso","kind":"rest","ceiling":0.6,"steps":[]},"coachNote":"Para."}"#)
        XCTAssertEqual(p.readiness.score, 20, "a missing score takes the level's default")
        XCTAssertEqual(p.readiness.summary, "", "no words from the model → nothing invented")
        XCTAssertTrue(p.workout.steps.isEmpty)
        XCTAssertEqual(p.workout.intensityCeiling, 0)
    }

    func testCeilingIsRaisedToTheHardestStepNeverBelowIt() throws {
        let p = try parse(#"{"readiness":{"level":"normal"},"workout":{"name":"x","kind":"vo2max","ceiling":0.9,"steps":[{"name":"w","minutes":10,"intensity":0.6},{"name":"on","minutes":3,"intensity":1.2}]}}"#)
        XCTAssertEqual(p.workout.intensityCeiling, 1.2)
    }

    func testUnsafeAnswersAreRejected() {
        XCTAssertThrowsError(try parse(#"{"readiness":{"level":"meh"},"workout":{"name":"x","kind":"endurance","steps":[{"name":"a","minutes":10,"intensity":0.6}]}}"#)) {
            XCTAssertEqual($0 as? DailyPrescription.ValidationError, .unknownReadiness("meh"))
        }
        XCTAssertThrowsError(try parse(#"{"readiness":{"level":"normal"},"workout":{"name":"x","kind":"yoga","steps":[{"name":"a","minutes":10,"intensity":0.6}]}}"#)) {
            XCTAssertEqual($0 as? DailyPrescription.ValidationError, .unknownKind("yoga"))
        }
        XCTAssertThrowsError(try parse(#"{"readiness":{"level":"normal"},"workout":{"name":"x","kind":"endurance","steps":[]}}"#)) {
            XCTAssertEqual($0 as? DailyPrescription.ValidationError, .noSteps)
        }
        // 2.0 × FTP in ERG mode is never something the trainer should receive; 20 % FTP on a work block is a mistake too.
        XCTAssertThrowsError(try parse(#"{"readiness":{"level":"normal"},"workout":{"name":"x","kind":"vo2max","steps":[{"name":"a","minutes":3,"intensity":2.0}]}}"#))
        XCTAssertThrowsError(try parse(#"{"readiness":{"level":"normal"},"workout":{"name":"x","kind":"recovery","steps":[{"name":"a","minutes":30,"intensity":0.2}]}}"#))
        // The time limit is enforced with a small tolerance: 60 available → cap 71: 72 min fails, 71 passes.
        XCTAssertThrowsError(try parse(#"{"readiness":{"level":"normal"},"workout":{"name":"x","kind":"endurance","steps":[{"name":"a","minutes":72,"intensity":0.65}]}}"#, available: 60)) {
            XCTAssertEqual($0 as? DailyPrescription.ValidationError, .tooLong(72))
        }
        XCTAssertNoThrow(try parse(#"{"readiness":{"level":"normal"},"workout":{"name":"x","kind":"endurance","steps":[{"name":"a","minutes":71,"intensity":0.65}]}}"#, available: 60))
        XCTAssertThrowsError(try parse(#"{"readiness":{"level":"normal"},"workout":{"name":"x","kind":"endurance","steps":[{"name":"a","minutes":10,"intensity":0.6}]},"week":[{"day":"next tuesday","kind":"rest"}]}"#)) {
            XCTAssertEqual($0 as? DailyPrescription.ValidationError, .badDay("next tuesday"))
        }
    }

    func brief(legs: SubjectiveFeedback.Legs? = nil, hrv: Double = 60, available: Int? = 75) -> CoachBrief {
        let wellness = (0..<30).map { i in WellnessDay(day: today.adding(days: -i), hrvMs: i == 0 ? hrv : 58, restingHR: 48, sleepSeconds: 7 * 3600 + 1800, ctl: 60, atl: 70) }
        let rides = (1...3).map { i in ActivitySummary(id: "a\(i)", name: "Ride \(i)", type: "Ride", startDateLocal: today.adding(days: -i).date(), movingTime: 3600, trainingLoad: 60, intensity: 72, isTrainer: true) }
        let old = ActivitySummary(id: "old", name: "Old", type: "Ride", startDateLocal: today.adding(days: -40).date(), movingTime: 3600, isTrainer: false)
        let plan = PlanBuilder().build(.init(goal: .ftp, startDay: today.adding(days: -14), endDay: today.adding(days: 42), availability: .typical))
        let feedback: [Day: SubjectiveFeedback] = legs.map { [today: SubjectiveFeedback(day: today, legs: $0)] } ?? [:]
        return CoachBrief(today: today, locale: "es", athlete: .init(ftp: 198, weightKg: 72),
                          ftpEstimate: FTPEstimate(watts: 179, confidence: .moderate, sustainedEfforts: 0, basis: "20 min × 0.95", windowDays: 42),
                          powerCurve: [.init(seconds: 300, watts: 240), .init(seconds: 1200, watts: 188), .init(seconds: 7, watts: 800)],
                          wellness: wellness, feedback: feedback, activities: rides + [old], plan: plan, upcomingEvent: nil,
                          availableMinutes: available, recentCoachNotes: [], measured: baseline)
    }

    func testBriefIsWindowedCompactAndCarriesTheBaseline() throws {
        let b = brief(legs: .heavy)
        XCTAssertEqual(b.wellness.count, 29, "28 days back through today")
        XCTAssertEqual(b.wellness.last?.day, today.iso)
        XCTAssertEqual(b.wellness.last?.legs, "heavy")
        XCTAssertEqual(b.wellness.last?.sleepH, 7.5)
        XCTAssertEqual(b.wellness.last?.tsb, -10)
        XCTAssertEqual(b.activities.map(\.name), ["Ride 3", "Ride 2", "Ride 1"], "oldest first, 40-day-old ride excluded")
        XCTAssertEqual(b.activities.last?.ifx, 0.72)
        XCTAssertEqual(b.powerCurve, ["5m": 240, "20m": 188], "only the standard durations")
        XCTAssertEqual(b.ftpEstimate, "179 W (moderate confidence, 20 min × 0.95, 0 sustained efforts in 42 d)")
        XCTAssertEqual(b.measured.signals, ["hrv: typical (61.0, usual 55.0–68.0)"])
        XCTAssertEqual(b.measured.missingData, ["sleep"])
        XCTAssertNotNil(b.plan?.phase)
        XCTAssertFalse(b.plan!.next7Days.isEmpty)
        XCTAssertTrue(b.plan!.next7Days.allSatisfy { Day(iso: $0.day)! >= today && Day(iso: $0.day)! <= today.adding(days: 7) })
        let json = try AICoachPrompt.userMessage(b)
        XCTAssertTrue(json.contains("\"ftp\":198"))
        XCTAssertFalse(json.contains("sourceSignals"), "structured signals stay in the app; the model gets the text")
        XCTAssertFalse(json.contains("baseline"), "nothing is pre-decided for the model")
        XCTAssertLessThan(json.count, 12_000, "the brief stays small enough to send on every refresh")
    }

    func testFingerprintChangesWithWhatShouldTriggerANewDecision() {
        let base = brief()
        XCTAssertEqual(base.fingerprint, brief().fingerprint, "same inputs → same key, no new call")
        XCTAssertNotEqual(base.fingerprint, brief(legs: .heavy).fingerprint)
        XCTAssertNotEqual(base.fingerprint, brief(hrv: 40).fingerprint)
        XCTAssertNotEqual(base.fingerprint, brief(available: 45).fingerprint)
    }

    func testPrescribeSendsTheExpertPromptOnThePlanRouteAndRejectsUnsafeOutput() async throws {
        let answer = #"{"readiness":{"level":"easy","score":40,"headline":"Suave hoy","rationale":"HRV 60 vs 58 habitual, piernas pesadas."},"workout":{"name":"Z2 corto","kind":"endurance","ceiling":0.7,"rationale":"Mantén el volumen.","steps":[{"name":"Calentamiento","minutes":10,"from":0.45,"to":0.6},{"name":"Z2","minutes":45,"intensity":0.65},{"name":"Vuelta a la calma","minutes":5,"from":0.55,"to":0.4}]},"week":[],"coachNote":"Mañana vemos.","flags":[]}"#
        let sse = "data: {\"type\":\"response.output_text.delta\",\"delta\":\(try String(decoding: JSONEncoder().encode(answer), as: UTF8.self))}\n\nevent: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\"}}\n\n"
        let t = FakeTransport(responses: [HTTPResponse(status: 200, body: Data(sse.utf8))])
        let coach = LLMCoach(transport: t, backend: .chatGPTPlan(accessToken: "tok"), model: "gpt-6-astra")
        let p = try await coach.prescribe(brief: brief(legs: .heavy))
        XCTAssertEqual(p.readiness.level, .easy)
        XCTAssertEqual(p.workout.totalDuration, 3600)
        XCTAssertEqual(p.model, "gpt-6-astra")

        let body = try JSONSerialization.jsonObject(with: t.requests[0].body!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "gpt-6-astra")
        XCTAssertEqual(body["store"] as? Bool, false)
        let instructions = body["instructions"] as! String
        XCTAssertTrue(instructions.contains("expert road-cycling coach"))
        XCTAssertTrue(instructions.contains("(es)"))
        let input = body["input"] as! [[String: Any]]
        XCTAssertTrue((input[0]["content"] as! String).contains("\"legs\":\"heavy\""))

        // A 3-hour session when the athlete has 75 min is thrown away, not softened.
        let long = #"{"readiness":{"level":"strong"},"workout":{"name":"x","kind":"longRide","steps":[{"name":"a","minutes":180,"intensity":0.65}]}}"#
        let t2 = FakeTransport(responses: [HTTPResponse(status: 200, body: Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\(try String(decoding: JSONEncoder().encode(long), as: UTF8.self))}\n\nevent: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{}}\n\n".utf8))])
        do {
            _ = try await LLMCoach(transport: t2, backend: .chatGPTPlan(accessToken: "tok")).prescribe(brief: brief())
            XCTFail("expected rejection")
        } catch { XCTAssertEqual(error as? DailyPrescription.ValidationError, .tooLong(180)) }

        // Plan errors still surface as such so the UI can show "manage usage".
        let t3 = FakeTransport(responses: [HTTPResponse(status: 429, body: Data(#"{"error":{"code":"subscription_sharing_usage_limit_exceeded"}}"#.utf8))])
        do {
            _ = try await LLMCoach(transport: t3, backend: .chatGPTPlan(accessToken: "tok")).prescribe(brief: brief())
            XCTFail("expected usage limit")
        } catch { XCTAssertEqual(error as? LLMCoachError, .usageLimitReached) }
    }
}
