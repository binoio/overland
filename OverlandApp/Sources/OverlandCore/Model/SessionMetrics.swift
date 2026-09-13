import Foundation

public struct SessionMetrics: Equatable, Sendable {
    public var bytesReceived: UInt64
    public var bytesSent: UInt64
    public var packetsReceived: UInt64
    public var packetsSent: UInt64
    public var duration: TimeInterval

    public init(
        bytesReceived: UInt64 = 0,
        bytesSent: UInt64 = 0,
        packetsReceived: UInt64 = 0,
        packetsSent: UInt64 = 0,
        duration: TimeInterval = 0
    ) {
        self.bytesReceived = bytesReceived
        self.bytesSent = bytesSent
        self.packetsReceived = packetsReceived
        self.packetsSent = packetsSent
        self.duration = duration
    }

    public var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    public var formattedBytesReceived: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesReceived), countStyle: .file)
    }

    public var formattedBytesSent: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesSent), countStyle: .file)
    }
}
