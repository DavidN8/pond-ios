//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatchaProtocol
import Testing

@MainActor
struct ChangePasswordScreenViewModelTests {
    private let clientProxy = ClientProxyMock(.init())
    private let viewModel: ChangePasswordScreenViewModel
    
    private var context: ChangePasswordScreenViewModelType.Context {
        viewModel.context
    }
    
    init() {
        viewModel = ChangePasswordScreenViewModel(clientProxy: clientProxy, userIndicatorController: UserIndicatorControllerMock())
    }
    
    // MARK: - Screen
    
    @Test
    func savesOnlyWhenTheNewPasswordsMatch() {
        context.oldPassword = "old"
        context.newPassword = "new password"
        context.confirmedPassword = "new pasword"
        #expect(!context.viewState.canSave)
        #expect(context.viewState.showsMismatch)
        
        context.confirmedPassword = "new password"
        #expect(context.viewState.canSave)
        #expect(!context.viewState.showsMismatch)
        
        context.oldPassword = ""
        #expect(!context.viewState.canSave)
    }
    
    @Test
    func changesThePasswordAndGoesBack() async throws {
        clientProxy.changePasswordOldPasswordNewPasswordReturnValue = .success(())
        fill()
        
        let deferred = deferFulfillment(viewModel.actionsPublisher) { $0 == .passwordChanged }
        context.send(viewAction: .save)
        try await deferred.fulfill()
        
        #expect(clientProxy.changePasswordOldPasswordNewPasswordReceivedArguments?.oldPassword == "old")
        #expect(clientProxy.changePasswordOldPasswordNewPasswordReceivedArguments?.newPassword == "new password")
        #expect(context.alertInfo == nil)
    }
    
    @Test
    func saysWhenTheCurrentPasswordIsWrong() async throws {
        clientProxy.changePasswordOldPasswordNewPasswordReturnValue = .failure(.wrongPassword)
        fill()
        
        let deferred = deferFulfillment(context.observe(\.viewState.bindings.alertInfo)) { $0 != nil }
        context.send(viewAction: .save)
        try await deferred.fulfill()
        
        #expect(context.alertInfo?.message == UntranslatedL10n.screenMatchaChangePasswordErrorWrongPassword)
    }
    
    // MARK: - Request
    
    @Test
    func requestAuthenticatesWithTheCurrentPasswordAndKeepsOtherDevices() throws {
        let request = try #require(PasswordChangeRequest.request(homeserverURL: "https://matrix.example.org/", accessToken: "token",
                                                                 userID: "@alice:example.org", oldPassword: "old", newPassword: "new"))
        
        #expect(request.url?.absoluteString == "https://matrix.example.org/_matrix/client/v3/account/password")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) }.flatMap(JSONValue.init(json:)))
        #expect(body == JSONValue(json: #"""
        {"new_password": "new", "logout_devices": false,
         "auth": {"type": "m.login.password", "identifier": {"type": "m.id.user", "user": "@alice:example.org"}, "password": "old"}}
        """#))
        #expect(PasswordChangeRequest.request(homeserverURL: "file:///etc", accessToken: "token",
                                              userID: "@alice:example.org", oldPassword: "old", newPassword: "new") == nil)
    }
    
    @Test
    func responsesMapToFailures() {
        #expect(failure(status: 200, body: "{}") == nil)
        #expect(failure(status: 401, body: #"{"errcode": "M_FORBIDDEN", "error": "Invalid password"}"#) == .wrongPassword)
        #expect(failure(status: 400, body: #"{"errcode": "M_WEAK_PASSWORD", "error": "Too short"}"#) == .rejected("Too short"))
        // A 401 without M_FORBIDDEN is an expired session or another sign-in stage, not a wrong password.
        #expect(failure(status: 401, body: #"{"errcode": "M_UNKNOWN_TOKEN"}"#) == .failed)
        #expect(failure(status: 502, body: "<html>") == .failed)
    }
    
    // MARK: - Helpers
    
    private func fill() {
        context.oldPassword = "old"
        context.newPassword = "new password"
        context.confirmedPassword = "new password"
    }
    
    private func failure(status: Int, body: String) -> PasswordChangeFailure? {
        if case .failure(let failure) = PasswordChangeRequest.result(status: status, body: Data(body.utf8)) {
            failure
        } else {
            nil
        }
    }
}
