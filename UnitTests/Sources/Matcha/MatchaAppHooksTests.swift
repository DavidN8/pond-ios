//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import Testing

struct MatchaAppHooksTests {
    @Test
    func keepsUpstreamsServersAndPointsTheLegalLinksAtTheRepository() {
        let appSettings = MatchaAppSettingsHook { VolatileUserDefaults() }.configure(.volatile())
        
        #expect(appSettings.accountProviders == AppSettings.volatile().accountProviders)
        #expect(appSettings.allowOtherAccountProviders)
        #expect([appSettings.websiteURL, appSettings.copyrightURL, appSettings.acceptableUseURL, appSettings.privacyURL].allSatisfy { $0.absoluteString.hasPrefix("https://github.com/DavidN8/pond-ios") })
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
    func hidesCalls() {
        let userHooks = MatchaUserSessionHook().makeUserHooks(for: ClientProxyMock(.init()))
        let roomProxy = JoinedRoomProxyMock(.init(isDirect: true))
        
        let roomScreen = RoomScreenViewState(roomAvatar: .room(id: roomProxy.id, name: nil, avatarURL: nil), hasOngoingCall: true, isDM: true, hasSuccessor: false)
        let roomDetails = RoomDetailsScreenViewState(details: roomProxy.details, isEncrypted: true, isDirect: true, joinedMembersCount: 2, bindings: .init())
        let memberDetails = RoomMemberDetailsScreenViewState(userID: "@alice:example.com", bindings: .init())
        let userProfile = UserProfileScreenViewState(userID: "@alice:example.com", isOwnUser: false, isPresentedModally: false, bindings: .init())
        
        #expect(!userHooks.roomScreenHook.update(roomScreen).isCallingEnabled)
        #expect(!userHooks.roomDetailsScreenHook.update(roomDetails).isCallingEnabled)
        #expect(!userHooks.roomMemberDetailsScreenHook.update(memberDetails).isCallingEnabled)
        #expect(!userHooks.userProfileScreenHook.update(userProfile).isCallingEnabled)
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
        let coordinator = RoomScreenCoordinator(parameters: .init(userSession: UserSessionMock(.init(clientProxy: clientProxy, userHooks: userHooks)),
                                                                  roomProxy: JoinedRoomProxyMock(.init()),
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
        
        #expect(coordinator.timelineViewModel.context.viewState.isCallJoiningHidden == callsHidden)
    }
}
