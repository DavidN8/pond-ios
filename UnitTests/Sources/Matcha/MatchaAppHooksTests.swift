//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import MatrixRustSDKMocks
import Testing

struct MatchaAppHooksTests {
    @Test
    func keepsUpstreamsServersAndPointsTheLegalLinksAtTheRepository() {
        let appSettings = MatchaAppSettingsHook { VolatileUserDefaults() }.configure(.volatile())
        
        #expect(appSettings.accountProviders == AppSettings.volatile().accountProviders)
        #expect(appSettings.allowOtherAccountProviders)
        #expect([appSettings.websiteURL, appSettings.copyrightURL, appSettings.acceptableUseURL, appSettings.privacyURL].allSatisfy { $0.absoluteString.hasPrefix("https://github.com/DavidN8/pond-ios") })
        #expect(appSettings.pushGatewayNotifyEndpoint.absoluteString == "https://matrix.matchahoneylatte.com/_matrix/push/v1/notify")
    }
    
    @Test
    func theNSEBuildsItsClientWithThreadsAndLabsStillWins() {
        let shared = VolatileUserDefaults()
        let hook = MatchaAppSettingsHook { shared }
        _ = hook.configure(AppSettings(store: shared))
        // The NSE reads the app group's defaults without running the hook.
        #expect(AppSettings(store: shared).threadsEnabled)
        
        let labs = AppSettings(store: shared)
        labs.threadsEnabled = false
        _ = hook.configure(AppSettings(store: shared))
        #expect(!AppSettings(store: shared).threadsEnabled)
    }
    
    @Test
    func threadsStayOnAfterTheFirstLaunchWipesTheStoredSettings() throws {
        let suiteName = "MatchaAppHooksTests.\(UUID().uuidString)"
        let shared = try #require(TrackedUserDefaults(suiteName: suiteName))
        defer { shared.reset() }
        let appSettings = MatchaAppSettingsHook { TrackedUserDefaults(suiteName: suiteName) }.configure(AppSettings(store: shared))
        
        // A first launch after installing wipes the stored settings after the hook ran (`AppCoordinator.wipeUserData`).
        appSettings.resetAllSettings()
        #expect(appSettings.threadsEnabled)
    }
    
    @Test
    func showsCallsOnceTheHomeserverSupportsLiveKit() async throws {
        let clientProxy = ClientProxyMock(.init())
        clientProxy.underlyingIsLiveKitRTCSupported = true
        let userHooks = MatchaUserSessionHook().makeUserHooks(for: clientProxy)
        #expect(callButtons(of: userHooks) == [false, false, false, false]) // While the check runs.
        
        try await finishCheck(of: userHooks)
        #expect(callButtons(of: userHooks) == [true, true, true, true])
    }
    
    @Test
    func hidesCallsWhenTheHomeserverDoesntSupportLiveKit() async throws {
        let clientProxy = ClientProxyMock(.init())
        clientProxy.underlyingIsLiveKitRTCSupported = false
        let userHooks = MatchaUserSessionHook().makeUserHooks(for: clientProxy)
        
        try await finishCheck(of: userHooks)
        #expect(clientProxy.isLiveKitRTCSupportedCalled)
        #expect(callButtons(of: userHooks) == [false, false, false, false])
    }
    
    @Test
    func hidesCallsWhenTheCheckFails() async throws {
        // The real proxy, as it is the one that turns the SDK's error into "unsupported".
        let client = ClientSDKMock(.init(userID: "@alice:matrix.org"))
        client.isLivekitRtcSupportedClosure = { throw ClientSDKMock.MockError.generic }
        let clientProxy = try await ClientProxy(client: client,
                                                networkMonitor: NetworkMonitorMock(.init()),
                                                userSettings: AppSettings.volatile().userSettings(for: "@alice:matrix.org"),
                                                analyticsService: AnalyticsServiceMock(.init()))
        let userHooks = MatchaUserSessionHook().makeUserHooks(for: clientProxy)
        
        try await finishCheck(of: userHooks)
        #expect(client.isLivekitRtcSupportedCalled)
        #expect(callButtons(of: userHooks) == [false, false, false, false])
    }
    
    @Test
    func checksAgainOnceTheHomeserverIsReachableAgain() async throws {
        let clientProxy = ClientProxyMock(.init())
        let reachability = CurrentValueSubject<HomeserverReachability, Never>(.reachable)
        clientProxy.homeserverReachabilityPublisher = reachability.asCurrentValuePublisher()
        clientProxy.underlyingIsLiveKitRTCSupported = false // The first check failed, say offline.
        let userHooks = MatchaUserSessionHook().makeUserHooks(for: clientProxy)
        try await finishCheck(of: userHooks)
        
        clientProxy.underlyingIsLiveKitRTCSupported = true
        reachability.send(.suspended)
        reachability.send(.reachable)
        try await finishCheck(of: userHooks)
        #expect(clientProxy.isLiveKitRTCSupportedCallsCount == 2)
        #expect(callButtons(of: userHooks) == [true, true, true, true])
    }
    
    @Test
    func checksAgainWhenSyncStartsAfterAnOfflineLaunch() async throws {
        let clientProxy = ClientProxyMock(.init())
        // The real proxy starts at .reachable, and an offline launch never changes it before sync starts.
        let reachability = CurrentValueSubject<HomeserverReachability, Never>(.reachable)
        clientProxy.homeserverReachabilityPublisher = reachability.asCurrentValuePublisher()
        clientProxy.underlyingIsLiveKitRTCSupported = false
        let userHooks = MatchaUserSessionHook().makeUserHooks(for: clientProxy)
        try await finishCheck(of: userHooks)
        
        clientProxy.underlyingIsLiveKitRTCSupported = true
        reachability.send(.reachable)
        try await finishCheck(of: userHooks)
        #expect(clientProxy.isLiveKitRTCSupportedCallsCount == 2)
        #expect(callButtons(of: userHooks) == [true, true, true, true])
    }
    
    @Test
    func screensBuiltBeforeTheCheckFinishesShowCallsOnceItDoes() async throws {
        let clientProxy = ClientProxyMock(.init())
        clientProxy.underlyingIsLiveKitRTCSupported = true
        let userSession = UserSessionMock(.init(clientProxy: clientProxy, userHooks: MatchaUserSessionHook().makeUserHooks(for: clientProxy)))
        let roomProxy = JoinedRoomProxyMock(.init(isDirect: true))
        roomProxy.getMemberUserIDClosure = { _ in .success(RoomMemberProxyMock.mockAlice) }
        
        let room = makeRoomScreen(userSession: userSession, roomProxy: roomProxy)
        let roomDetails = RoomDetailsScreenViewModel(roomProxy: roomProxy,
                                                     userSession: userSession,
                                                     analyticsService: AnalyticsServiceMock(.init()),
                                                     userIndicatorController: UserIndicatorControllerMock(),
                                                     notificationSettingsProxy: NotificationSettingsProxyMock(with: .init()),
                                                     attributedStringBuilder: AttributedStringBuilder(mentionBuilder: MentionBuilder()))
        let memberDetails = RoomMemberDetailsScreenViewModel(userID: RoomMemberProxyMock.mockAlice.userID,
                                                             roomProxy: roomProxy,
                                                             userSession: userSession,
                                                             analytics: AnalyticsServiceMock(.init()),
                                                             userIndicatorController: UserIndicatorControllerMock())
        let userProfile = UserProfileScreenViewModel(userID: RoomMemberProxyMock.mockAlice.userID,
                                                     isPresentedModally: false,
                                                     userSession: userSession,
                                                     analytics: AnalyticsServiceMock(.init()),
                                                     userIndicatorController: UserIndicatorControllerMock())
        // The room screen's own state is private; its timeline's Join button follows it.
        #expect(room.timelineViewModel.context.viewState.isCallJoiningHidden)
        #expect(!roomDetails.context.viewState.isCallingEnabled)
        #expect(!memberDetails.context.viewState.isCallingEnabled)
        #expect(!userProfile.context.viewState.isCallingEnabled)
        
        try await finishCheck(of: userSession.userHooks)
        #expect(!room.timelineViewModel.context.viewState.isCallJoiningHidden)
        #expect(roomDetails.context.viewState.isCallingEnabled)
        #expect(memberDetails.context.viewState.isCallingEnabled)
        #expect(userProfile.context.viewState.isCallingEnabled)
    }
    
    @Test
    func theTimelineCantJoinACallWhileCallsAreHidden() {
        let timeline = TimelineViewModel.mock(timelineKind: .live)
        var presentedCalls = 0
        let cancellable = timeline.actions.sink { action in
            if case .presentCallScreen = action {
                presentedCalls += 1
            }
        }
        
        timeline.context.send(viewAction: .joinActiveCall(isVoiceCall: false))
        #expect(presentedCalls == 1)
        
        timeline.state.isCallJoiningHidden = true
        timeline.context.send(viewAction: .joinActiveCall(isVoiceCall: false))
        #expect(presentedCalls == 1)
        cancellable.cancel()
    }
    
    @Test(arguments: [false, true])
    func theRoomScreenGivesItsTimelineTheCallRule(callsHidden: Bool) {
        let clientProxy = ClientProxyMock(.init())
        let userHooks = callsHidden ? MatchaUserSessionHook().makeUserHooks(for: clientProxy) : UserHooks()
        let coordinator = makeRoomScreen(userSession: UserSessionMock(.init(clientProxy: clientProxy, userHooks: userHooks)), roomProxy: JoinedRoomProxyMock(.init()))
        
        #expect(coordinator.timelineViewModel.context.viewState.isCallJoiningHidden == callsHidden)
    }
    
    // MARK: - Helpers
    
    /// Whether the room, room details, member details and user profile screens offer calls.
    private func callButtons(of userHooks: UserHooks) -> [Bool] {
        let roomProxy = JoinedRoomProxyMock(.init(isDirect: true))
        let roomScreen = RoomScreenViewState(roomAvatar: .room(id: roomProxy.id, name: nil, avatarURL: nil), hasOngoingCall: true, isDM: true, hasSuccessor: false)
        let roomDetails = RoomDetailsScreenViewState(details: roomProxy.details, isEncrypted: true, isDirect: true, joinedMembersCount: 2, bindings: .init())
        let memberDetails = RoomMemberDetailsScreenViewState(userID: "@alice:example.com", bindings: .init())
        let userProfile = UserProfileScreenViewState(userID: "@alice:example.com", isOwnUser: false, isPresentedModally: false, bindings: .init())
        return [userHooks.roomScreenHook.update(roomScreen).isCallingEnabled,
                userHooks.roomDetailsScreenHook.update(roomDetails).isCallingEnabled,
                userHooks.roomMemberDetailsScreenHook.update(memberDetails).isCallingEnabled,
                userHooks.userProfileScreenHook.update(userProfile).isCallingEnabled]
    }
    
    /// Waits for the LiveKit check the hooks started. Call it before the test first suspends, as the check's task runs then.
    private func finishCheck(of userHooks: UserHooks) async throws {
        let callsHook = try #require(userHooks.roomScreenHook as? MatchaCallsHook)
        try await deferFulfillment(callsHook.$isSupported.dropFirst()) { _ in true }.fulfill()
    }
    
    private func makeRoomScreen(userSession: UserSessionProtocol, roomProxy: JoinedRoomProxyProtocol) -> RoomScreenCoordinator {
        RoomScreenCoordinator(parameters: .init(userSession: userSession,
                                                roomProxy: roomProxy,
                                                timelineController: TimelineControllerMock(.init()),
                                                mediaPlayerProvider: MediaPlayerProviderMock(),
                                                emojiProvider: EmojiProvider(userSettings: .mock()),
                                                linkMetadataProvider: LinkMetadataProvider(),
                                                completionSuggestionService: CompletionSuggestionServiceMock(configuration: .init()),
                                                ongoingCallRoomIDPublisher: .init(.init(nil)),
                                                appMediator: AppMediatorMock(.init()),
                                                analytics: AnalyticsServiceMock(.init()),
                                                composerDraftService: ComposerDraftServiceMock(.init()),
                                                timelineControllerFactory: TimelineControllerFactoryMock(.init()),
                                                userIndicatorController: UserIndicatorControllerMock()))
    }
}
