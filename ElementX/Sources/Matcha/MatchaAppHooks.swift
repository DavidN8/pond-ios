//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

// Matcha configures the app through upstream's fork hooks, so no upstream setting or screen is edited. Tests, previews
// and snapshots never call `setUp()` and keep upstream's defaults; the extensions don't compile this file.
nonisolated extension AppHooks {
    func setUp() {
        registerAppSettingsHook(MatchaAppSettingsHook())
        registerUserSessionHook(MatchaUserSessionHook())
        registerCompoundHook(MatchaCompoundHook())
    }
}

/// Configures POND: threads on by default and its legal links. Sign in keeps upstream's servers, so users type their own.
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
        // after this hook runs. ponytail: the NSE then reads off until the app's next launch stores it again; harmless until I13.
        UserDefaults(suiteName: AppSettings.suiteName)?.register(defaults: [threadsKey: true])
        // ponytail: password-only homeserver, so the OAuth redirect stays Element's. POND's pages live in its public repository.
        appSettings.override(accountProviders: appSettings.accountProviders,
                             allowOtherAccountProviders: appSettings.allowOtherAccountProviders,
                             hideBrandChrome: appSettings.hideBrandChrome,
                             pushGatewayBaseURL: appSettings.pushGatewayBaseURL,
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
    /// Calls stay hidden until the homeserver advertises a LiveKit focus (`rtc_foci`), platform plan decision 17.
    static let callsEnabled = false
    
    @MainActor func makeUserHooks(for clientProxy: ClientProxyProtocol) -> UserHooks {
        guard !Self.callsEnabled else { return UserHooks() }
        
        let hiddenCallsHook = MatchaHiddenCallsHook()
        return UserHooks(roomScreenHook: hiddenCallsHook,
                         roomDetailsScreenHook: hiddenCallsHook,
                         roomMemberDetailsScreenHook: hiddenCallsHook,
                         userProfileScreenHook: hiddenCallsHook)
    }
    
    func configure(_ userSettings: UserSettings, forHomeserver homeserver: String) -> UserSettings {
        userSettings
    }
}

/// Hides the call buttons of the room header, room details, member details and user profile screens.
struct MatchaHiddenCallsHook: RoomScreenHookProtocol, RoomDetailsScreenHookProtocol, RoomMemberDetailsScreenHookProtocol, UserProfileScreenHookProtocol {
    func update(_ viewState: RoomScreenViewState) -> RoomScreenViewState {
        var viewState = viewState
        viewState.isCallingEnabled = false
        return viewState
    }
    
    func update(_ viewState: RoomDetailsScreenViewState) -> RoomDetailsScreenViewState {
        var viewState = viewState
        viewState.isCallingEnabled = false
        return viewState
    }
    
    func update(_ viewState: RoomMemberDetailsScreenViewState) -> RoomMemberDetailsScreenViewState {
        var viewState = viewState
        viewState.isCallingEnabled = false
        return viewState
    }
    
    func update(_ viewState: UserProfileScreenViewState) -> UserProfileScreenViewState {
        var viewState = viewState
        viewState.isCallingEnabled = false
        return viewState
    }
}
