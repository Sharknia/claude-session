import CryptoKit
import Darwin
import Foundation

struct ClaudeOAuthCallback: Equatable {
    let code: String?
    let state: String?
    let error: String?
}

final class ClaudeOAuthLoopback: @unchecked Sendable {
    let redirectURI: String
    private let lock = NSLock()
    private var socketFD: Int32

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ClaudeServiceError.loginCaptureFailed }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw ClaudeServiceError.loginCaptureFailed
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard resolved == 0 else {
            close(descriptor)
            throw ClaudeServiceError.loginCaptureFailed
        }

        socketFD = descriptor
        redirectURI = "http://localhost:\(UInt16(bigEndian: assigned.sin_port))/callback"
    }

    deinit {
        stop()
    }

    func stop() {
        lock.lock()
        let descriptor = socketFD
        socketFD = -1
        lock.unlock()
        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
    }

    func wait(expectedState: String, timeout: TimeInterval) throws -> ClaudeOAuthCallback {
        defer { stop() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let listeningDescriptor = socketFD
            lock.unlock()
            guard listeningDescriptor >= 0 else { throw CancellationError() }

            var descriptor = pollfd(fd: listeningDescriptor, events: Int16(POLLIN), revents: 0)
            let remainingMilliseconds = max(
                1,
                Int32(min(deadline.timeIntervalSinceNow * 1_000, Double(Int32.max)))
            )
            let ready = poll(&descriptor, 1, remainingMilliseconds)
            if ready == 0 { throw ClaudeServiceError.oauthLoginTimedOut }
            if ready < 0 {
                if errno == EINTR { continue }
                throw ClaudeServiceError.loginCaptureFailed
            }

            let client = accept(listeningDescriptor, nil, nil)
            guard client >= 0 else { continue }
            var noSignal: Int32 = 1
            setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            )

            guard let requestHead = readRequestHead(from: client),
                  let callback = Self.parseCallback(requestHead) else {
                Self.sendResponse(status: "404 Not Found", body: "Not found", to: client)
                close(client)
                continue
            }
            guard callback.state == expectedState,
                  (callback.code?.isEmpty == false || callback.error?.isEmpty == false) else {
                Self.sendResponse(status: "400 Bad Request", body: "Invalid callback", to: client)
                close(client)
                continue
            }
            Self.sendResponse(
                status: "200 OK",
                body: "<html><body>Claude login complete. You can close this tab.</body></html>",
                to: client
            )
            close(client)
            return callback
        }
        throw ClaudeServiceError.oauthLoginTimedOut
    }

    static func parseCallback(_ requestHead: String) -> ClaudeOAuthCallback? {
        guard let firstLine = requestHead.split(separator: "\n", omittingEmptySubsequences: false).first else {
            return nil
        }
        let parts = firstLine.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://localhost\(parts[1])"),
              components.path == "/callback" else {
            return nil
        }
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            parameters[item.name] = item.value ?? ""
        }
        return ClaudeOAuthCallback(
            code: parameters["code"],
            state: parameters["state"],
            error: parameters["error"]
        )
    }

    private func readRequestHead(from client: Int32) -> String? {
        var data = Data()
        while data.count < 8_192 {
            var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 500) > 0 else { return nil }
            var bytes = [UInt8](repeating: 0, count: 2_048)
            let count = read(client, &bytes, bytes.count)
            guard count > 0 else { return nil }
            data.append(bytes, count: count)
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        return String(data: data, encoding: .utf8)
    }

    private static func sendResponse(status: String, body: String, to client: Int32) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(bodyData)
        response.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = Darwin.write(client, baseAddress, buffer.count)
        }
    }
}

enum ClaudeOAuthFlow {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let scope = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    private static let authorizeEndpoint = "https://claude.com/cai/oauth/authorize"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    static func randomURLSafeString(byteCount: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return base64URL(bytes)
    }

    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func authorizeURL(codeChallenge: String, state: String, redirectURI: String) throws -> URL {
        let parameters: [(String, String)] = [
            ("code", "true"),
            ("client_id", clientID),
            ("response_type", "code"),
            ("redirect_uri", redirectURI),
            ("scope", scope),
            ("code_challenge", codeChallenge),
            ("code_challenge_method", "S256"),
            ("state", state)
        ]
        let query = parameters.map {
            "\($0.0)=\(encodeURIComponent($0.1).replacingOccurrences(of: "%20", with: "+"))"
        }.joined(separator: "&")
        guard let url = URL(string: "\(authorizeEndpoint)?\(query)") else {
            throw ClaudeServiceError.loginCaptureFailed
        }
        return url
    }

    static func makeTokenRequest(
        code: String,
        verifier: String,
        state: String,
        redirectURI: String
    ) throws -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
            "state": state
        ])
        return request
    }

    static func parseTokenResponse(_ data: Data, now: Date = Date()) throws -> ManagedClaudeCredential {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String, !accessToken.isEmpty,
              let refreshToken = object["refresh_token"] as? String, !refreshToken.isEmpty,
              let expiresIn = object["expires_in"] as? NSNumber else {
            throw ClaudeServiceError.loginCaptureFailed
        }
        let scopes = (object["scope"] as? String)?.split(separator: " ").map(String.init)
            ?? scope.split(separator: " ").map(String.init)
        return ManagedClaudeCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000)
                + Int64(expiresIn.doubleValue * 1_000),
            scopes: scopes
        )
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func encodeURIComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
