import CadenciaCore

// Literals for the domain's brands, in tests only: the app builds them through `init(_:) throws`, the
// `BackendID` helpers or decoding. A literal outside its brand stops the test.

protocol TextBrandLiteral: CadenciaAPI.Branded, ExpressibleByStringLiteral where RawValue == String {}
extension TextBrandLiteral {
    public init(stringLiteral value: String) {
        guard let branded = Self(rawValue: value) else { preconditionFailure("\(value) is not a valid \(Self.self)") }
        self = branded
    }
}

protocol IntBrandLiteral: CadenciaAPI.Branded, ExpressibleByIntegerLiteral where RawValue == Int {}
extension IntBrandLiteral {
    public init(integerLiteral value: Int) {
        guard let branded = Self(rawValue: value) else { preconditionFailure("\(value) is not a valid \(Self.self)") }
        self = branded
    }
}

protocol NumberBrandLiteral: CadenciaAPI.Branded, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral where RawValue == Double {}
extension NumberBrandLiteral {
    public init(floatLiteral value: Double) {
        guard let branded = Self(rawValue: value) else { preconditionFailure("\(value) is not a valid \(Self.self)") }
        self = branded
    }
    public init(integerLiteral value: Int) { self.init(floatLiteral: Double(value)) }
}

extension CadenciaAPI.AthleteId: TextBrandLiteral {}
extension CadenciaAPI.PlanId: TextBrandLiteral {}
extension CadenciaAPI.ConsultationId: TextBrandLiteral {}
extension CadenciaAPI.ConversationId: TextBrandLiteral {}
extension CadenciaAPI.DailyDecisionId: TextBrandLiteral {}
extension CadenciaAPI.MessageId: TextBrandLiteral {}
extension CadenciaAPI.SessionId: TextBrandLiteral {}
extension CadenciaAPI.ExternalId: TextBrandLiteral {}
extension CadenciaAPI.Day: TextBrandLiteral {}
extension CadenciaAPI.Fingerprint: TextBrandLiteral {}
extension CadenciaAPI.ModelName: TextBrandLiteral {}
extension CadenciaAPI.Title: TextBrandLiteral {}
extension CadenciaAPI.Headline: TextBrandLiteral {}
extension CadenciaAPI.Paragraph: TextBrandLiteral {}
extension CadenciaAPI.MessageText: TextBrandLiteral {}
extension CadenciaAPI.Minutes: IntBrandLiteral {}
extension CadenciaAPI.Attempt: IntBrandLiteral {}
extension CadenciaAPI.Weekday: IntBrandLiteral {}
extension CadenciaAPI.WeekNumber: IntBrandLiteral {}
extension CadenciaAPI.Count: IntBrandLiteral {}
extension CadenciaAPI.ReadinessScore: IntBrandLiteral {}
extension CadenciaAPI.CadenceRpm: IntBrandLiteral {}
extension CadenciaAPI.FtpWatts: IntBrandLiteral {}
extension CadenciaAPI.Seconds: NumberBrandLiteral {}
extension CadenciaAPI.FtpFraction: NumberBrandLiteral {}
extension CadenciaAPI.Kilometers: NumberBrandLiteral {}

/// Ids in the backend's shapes, for tests.
enum TestIDs {
    static let athlete: CadenciaAPI.AthleteId = "i100"
    static let plan: CadenciaAPI.PlanId = "i100:5f0c6a1e-2b3d-4c5e-8f60-7a8b9c0d1e2f"
    static let otherPlan: CadenciaAPI.PlanId = "i100:0a1b2c3d-4e5f-4a6b-8c7d-8e9f0a1b2c3d"
    static let consultation: CadenciaAPI.ConsultationId = "i100:c0ffee00-1234-4abc-9def-0123456789ab"
    /// The `n`th message of a test conversation.
    static func message(_ n: Int) -> CadenciaAPI.MessageId {
        CadenciaAPI.MessageId(rawValue: String(format: "00000000-0000-4000-8000-%012d", n))!
    }
    /// A fingerprint made of one hex digit.
    static func fingerprint(_ digit: Character) -> CadenciaAPI.Fingerprint {
        CadenciaAPI.Fingerprint(rawValue: String(repeating: digit, count: 64))!
    }
}
