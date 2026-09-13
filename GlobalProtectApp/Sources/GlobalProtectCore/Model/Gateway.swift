import Foundation

public struct Gateway: Identifiable, Equatable, Sendable, Codable, Hashable {
    public var id: String { server }
    public var name: String
    public var server: String
    public var priority: Int
    public var latencyMs: Double?
    public var isManual: Bool

    public init(
        name: String,
        server: String,
        priority: Int = 1,
        latencyMs: Double? = nil,
        isManual: Bool = false
    ) {
        self.name = name
        self.server = server
        self.priority = priority
        self.latencyMs = latencyMs
        self.isManual = isManual
    }

    private enum CodingKeys: String, CodingKey {
        case name, server, priority, latencyMs, isManual
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        server = try c.decode(String.self, forKey: .server)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 1
        latencyMs = try c.decodeIfPresent(Double.self, forKey: .latencyMs)
        isManual = try c.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
    }

    public var displayName: String {
        if name.isEmpty || name == server {
            return server
        }
        return "\(name) (\(server))"
    }

    public var latencyText: String {
        guard let ms = latencyMs else { return "– ms" }
        return String(format: "%.0f ms", ms)
    }
}
