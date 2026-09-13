import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Completes the external-browser login.
///
/// `gpclient connect --browser` serves the SAML page on localhost, then waits
/// on a second loopback port whose number it writes to `$TMPDIR/gpcallback.port`.
/// The identity provider ends the flow by redirecting the browser to
/// `globalprotectcallback:<data>`; macOS hands that URL to this app, and this
/// type relays the data to the waiting gpclient exactly as `gpclient
/// launch-gui <data>` does on Linux.
///
/// Plain POSIX sockets keep this portable (the core module also builds on
/// Linux for CI) and the payload is a single short write.
public struct AuthCallbackForwarder: Sendable {
    public static let portFileName = "gpcallback.port"

    public var temporaryDirectory: URL

    public init(temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory())) {
        self.temporaryDirectory = temporaryDirectory
    }

    public var portFileURL: URL {
        temporaryDirectory.appendingPathComponent(Self.portFileName)
    }

    public func readPort() -> UInt16? {
        guard let text = try? String(contentsOf: portFileURL, encoding: .utf8) else { return nil }
        return UInt16(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public enum ForwardError: Error, LocalizedError, Equatable {
        case noPendingLogin
        case connectionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noPendingLogin:
                return "No gpclient login is waiting for browser data (missing \(AuthCallbackForwarder.portFileName))."
            case .connectionFailed(let reason):
                return "Could not deliver browser authentication data to gpclient: \(reason)"
            }
        }
    }

    /// Send `authData` (the full `globalprotectcallback:` URL string) to the
    /// gpclient that is waiting for it.
    public func forward(authData: String) async throws {
        guard let port = readPort() else {
            throw ForwardError.noPendingLogin
        }
        let payload = authData
        try await Task.detached(priority: .userInitiated) {
            try Self.send(payload, toLoopbackPort: port)
        }.value
    }

    static func send(_ payload: String, toLoopbackPort port: UInt16) throws {
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw ForwardError.connectionFailed(Self.errnoString()) }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw ForwardError.connectionFailed(Self.errnoString()) }

        let bytes = Array(payload.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { buf in
                write(fd, buf.baseAddress, buf.count)
            }
            guard written > 0 else { throw ForwardError.connectionFailed(Self.errnoString()) }
            offset += written
        }
    }

    private static func errnoString() -> String {
        String(cString: strerror(errno))
    }
}
