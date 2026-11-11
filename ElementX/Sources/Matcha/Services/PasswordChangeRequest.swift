//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatchaProtocol
import MatrixRustSDK

enum PasswordChangeFailure: Error, Equatable {
    /// The homeserver didn't accept the current password.
    case wrongPassword
    /// The homeserver refused the new password (too weak, its password policy), with its reason.
    case rejected(String)
    case failed
}

/// Changes the account's password (`POST /account/password`), which the Rust SDK can't do. The current password goes in the request's
/// `auth`, as Element Web sends it, and other devices stay signed in (`logout_devices: false`), as on the web.
/// ponytail: app-level HTTP with the session's access token, as `RoomStateRequest`; use the SDK once its FFI has a call for it.
nonisolated enum PasswordChangeRequest {
    private static let urlSession = URLSession(configuration: .ephemeral)
    
    static func send(oldPassword: String, newPassword: String, userID: String, session: Session) async -> Result<Void, PasswordChangeFailure> {
        guard let request = request(homeserverURL: session.homeserverUrl, accessToken: session.accessToken,
                                    userID: userID, oldPassword: oldPassword, newPassword: newPassword) else {
            return .failure(.failed)
        }
        do {
            let (data, response) = try await urlSession.data(for: request)
            return result(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            MXLog.error("Changing the password failed: \(error)")
            return .failure(.failed)
        }
    }
    
    static func request(homeserverURL: String, accessToken: String, userID: String, oldPassword: String, newPassword: String) -> URLRequest? {
        let base = homeserverURL.hasSuffix("/") ? String(homeserverURL.dropLast()) : homeserverURL
        guard let url = URL(string: base + "/_matrix/client/v3/account/password"), ["https", "http"].contains(url.scheme) else {
            return nil
        }
        let auth = JSONValue.object(["type": .string("m.login.password"),
                                     "identifier": .object(["type": .string("m.id.user"), "user": .string(userID)]),
                                     "password": .string(oldPassword)])
        let body = JSONValue.object(["new_password": .string(newPassword), "logout_devices": .bool(false), "auth": auth])
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.jsonString.utf8)
        return request
    }
    
    static func result(status: Int, body: Data) -> Result<Void, PasswordChangeFailure> {
        guard status != 200 else { return .success(()) }
        let error = String(data: body, encoding: .utf8).flatMap(JSONValue.init(json:))?.objectValue
        let errcode = error?.string("errcode")
        // A wrong current password fails the request's authentication: 401 with M_FORBIDDEN (Synapse), or 403.
        if [401, 403].contains(status), errcode == "M_FORBIDDEN" {
            return .failure(.wrongPassword)
        }
        if status == 400, let message = error?.string("error"), !message.isEmpty {
            return .failure(.rejected(message))
        }
        MXLog.error("Changing the password failed with status \(status) \(errcode ?? "")")
        return .failure(.failed)
    }
}
