//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

// Matcha configures the app through upstream's fork hooks, so no upstream setting is edited and the screens only gain
// marked lines for calls: a late call check (`MatchaCallsHook`) and no Element Call analytics. Tests, previews and snapshots
// never call `setUp()` and keep upstream's defaults; the extensions don't compile this file.
nonisolated extension AppHooks {
    func setUp() {
        registerAppSettingsHook(MatchaAppSettingsHook())
        registerUserSessionHook(MatchaUserSessionHook())
        registerCompoundHook(MatchaCompoundHook())
    }
}

/// Configures POND: threads on by default, its legal links and its push gateway. Sign in keeps upstream's servers, so users
/// type their own.
struct MatchaAppSettingsHook: AppSettingsHookProtocol {
    /// The app group's defaults, which the NSE reads too.
    var sharedStore: @Sendable () -> UserDefaultsProtocol? = { TrackedUserDefaults(suiteName: AppSettings.suiteName) }
    
    func configure(_ appSettings: AppSettings) -> AppSettings {
        // Named threads need the SDK's threads (platform plan I1 step 5). Stored, not registered, since the NSE doesn't run this
        // hook and builds its client from the shared defaults; only an unset value is written, so a choice made in Labs stays.
        let threadsKey = appSettings.threadsEnabledKey.rawValue
        if let store = sharedStore(), store.object(forKey: threadsKey) == nil {
            store.set(true, forKey: threadsKey)
        }
        // Registered too, after the check above (a registered default reads as set): a first launch wipes the stored settings
        // after this hook runs. ponytail: the NSE then reads off until the app's next launch stores it again.
        UserDefaults(suiteName: AppSettings.suiteName)?.register(defaults: [threadsKey: true])
        // ponytail: password-only homeserver, so the OAuth redirect stays Element's. POND's pages live in its public repository.
        appSettings.override(accountProviders: appSettings.accountProviders,
                             allowOtherAccountProviders: appSettings.allowOtherAccountProviders,
                             hideBrandChrome: appSettings.hideBrandChrome,
                             // matrix.org's gateway has no APNs key for POND's app ID; POND's Sygnal has, for any homeserver.
                             pushGatewayBaseURL: "https://matrix.matchahoneylatte.com",
                             oAuthRedirectURL: appSettings.oAuthRedirectURL,
                             oAuthClientURIPath: appSettings.oAuthClientURIPath,
                             websiteURL: "https://github.com/DavidN8/pond-ios",
                             logoURL: appSettings.logoURL,
                             // The source code, credits and licence, as the AGPL asks of a modified version.
                             copyrightURL: "https://github.com/DavidN8/pond-ios#licence",
                             acceptableUseURL: "https://github.com/DavidN8/pond-ios/blob/matcha/TERMS.md",
                             privacyURL: "https://github.com/DavidN8/pond-ios/blob/matcha/PRIVACY.md",
                             encryptionURL: appSettings.encryptionURL,
                             deviceVerificationURL: appSettings.deviceVerificationURL,
                             chatBackupDetailsURL: appSettings.chatBackupDetailsURL,
                             identityPinningViolationDetailsURL: appSettings.identityPinningViolationDetailsURL,
                             historySharingDetailsURL: appSettings.historySharingDetailsURL,
                             elementWebHosts: appSettings.elementWebHosts,
                             accountProvisioningHost: appSettings.accountProvisioningHost,
                             bugReportApplicationID: appSettings.bugReportApplicationID,
                             analyticsTermsURL: appSettings.analyticsTermsURL,
                             mapTilerConfiguration: AppSettings.bundledMapTilerConfiguration)
        return appSettings
    }
}

nonisolated struct MatchaUserSessionHook: UserSessionHookProtocol {
    @MainActor func makeUserHooks(for clientProxy: ClientProxyProtocol) -> UserHooks {
        let callsHook = MatchaCallsHook(clientProxy: clientProxy)
        return UserHooks(roomScreenHook: callsHook,
                         roomDetailsScreenHook: callsHook,
                         roomMemberDetailsScreenHook: callsHook,
                         userProfileScreenHook: callsHook)
    }
    
    func configure(_ userSettings: UserSettings, forHomeserver homeserver: String) -> UserSettings {
        userSettings
    }
}

/// Shows the call buttons of the room header, room details, member details and user profile screens only when the session's
/// homeserver supports MatrixRTC on LiveKit (platform plan decision 17): hidden while the check runs and when it fails.
/// Not redundant: conforming to these `Sendable` protocols makes a type nonisolated by default.
@MainActor final class MatchaCallsHook: RoomScreenHookProtocol, RoomDetailsScreenHookProtocol, RoomMemberDetailsScreenHookProtocol, UserProfileScreenHookProtocol {
    /// A hook only shapes a screen's first state, so the four view models follow this for a result that comes later.
    @Published private(set) var isSupported = false
    private var reachabilityCancellable: AnyCancellable?
    
    init(clientProxy: ClientProxyProtocol) {
        // The proxy reads any error as no, so the check runs as the session starts and again each time the proxy reports the
        // homeserver reachable (sync starting or changing state, a resume from the background included) until it says yes.
        // No removeDuplicates: the subject starts at .reachable, so after an offline cold launch sync's first .reachable is
        // a repeat. ponytail: a request that fails while sync keeps running waits for the next report; retry on a timer if
        // that turns out to matter.
        reachabilityCancellable = clientProxy.homeserverReachabilityPublisher
            .filter { $0 == .reachable }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !isSupported else { return }
                Task {
                    let supported = await clientProxy.isLiveKitRTCSupported
                    self.isSupported = self.isSupported || supported // A late no from an earlier check can't undo a yes.
                }
            }
    }
    
    func update(_ viewState: RoomScreenViewState) -> RoomScreenViewState {
        var viewState = viewState
        viewState.isCallingEnabled = isSupported
        return viewState
    }
    
    func update(_ viewState: RoomDetailsScreenViewState) -> RoomDetailsScreenViewState {
        var viewState = viewState
        viewState.isCallingEnabled = isSupported
        return viewState
    }
    
    func update(_ viewState: RoomMemberDetailsScreenViewState) -> RoomMemberDetailsScreenViewState {
        var viewState = viewState
        viewState.isCallingEnabled = isSupported
        return viewState
    }
    
    func update(_ viewState: UserProfileScreenViewState) -> UserProfileScreenViewState {
        var viewState = viewState
        viewState.isCallingEnabled = isSupported
        return viewState
    }
}
