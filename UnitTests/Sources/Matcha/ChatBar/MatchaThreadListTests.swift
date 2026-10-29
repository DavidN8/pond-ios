//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Testing

@MainActor
struct MatchaThreadListTests {
    @Test
    func withoutTheMatchaWorkspacesEveryThreadIsShownWithoutChips() {
        let viewModel = RoomThreadListScreenViewModel(threadListServiceProxy: RoomThreadListServiceProxyMock(.init(items: .mocks)),
                                                      mediaProvider: MediaProviderMock(.init()))
        
        #expect(viewModel.context.archiveFilter == nil)
        #expect(viewModel.context.viewState.visibleItems.map(\.id) == [RoomThreadListItem].mocks.map(\.id))
    }
    
    @Test
    func theActiveAndArchivedChipsSplitTheThreads() {
        let threads = CurrentValueSubject<[String: MatchaThreadInfo], Never>(["1": MatchaThreadInfo(name: "Ping", isNamed: true, isArchived: true, hiddenReplies: 1)])
        let viewModel = RoomThreadListScreenViewModel(threadListServiceProxy: RoomThreadListServiceProxyMock(.init(items: .mocks)),
                                                      mediaProvider: MediaProviderMock(.init()),
                                                      matchaThreadsPublisher: threads.eraseToAnyPublisher())
        let allIDs = [RoomThreadListItem].mocks.map(\.id)
        
        #expect(viewModel.context.archiveFilter == .active)
        #expect(viewModel.context.viewState.visibleItems.map(\.id) == allIDs.filter { $0 != "1" })
        
        viewModel.context.archiveFilter = .archived
        #expect(viewModel.context.viewState.visibleItems.map(\.id) == ["1"])
        
        // Unarchived elsewhere, the thread moves back to Active.
        threads.send([:])
        #expect(viewModel.context.viewState.visibleItems.isEmpty)
        viewModel.context.archiveFilter = .active
        #expect(viewModel.context.viewState.visibleItems.map(\.id) == allIDs)
    }
}
