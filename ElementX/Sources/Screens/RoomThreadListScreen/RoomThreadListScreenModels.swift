//
// Copyright 2025 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

enum RoomThreadListScreenViewModelAction {
    case presentThread(threadRootEventID: String)
}

struct RoomThreadListScreenViewState: BindableState {
    var items = [RoomThreadListItem]()
    
    var isPaginating = false
    
    /// matcha: the chat's thread names, archive flags and hidden replies; empty while the chat shows no Matcha features.
    var matchaThreads: [String: MatchaThreadInfo] = [:]
    
    var bindings: RoomThreadListScreenViewStateBindings
    
    /// matcha: the threads the selected Active or Archived chip shows.
    var visibleItems: [RoomThreadListItem] {
        guard let filter = bindings.archiveFilter else { return items }
        return items.filter { (matchaThreads[$0.id]?.isArchived == true) == (filter == .archived) }
    }
}

struct RoomThreadListScreenViewStateBindings {
    /// matcha: the Active or Archived chip; nil shows every thread, without chips.
    var archiveFilter: ThreadArchiveFilter?
}

/// matcha: the chips of All threads.
enum ThreadArchiveFilter: CaseIterable {
    case active
    case archived
}

enum RoomThreadListScreenViewAction {
    case oldestItemDidAppear
    case oldestItemDidDisappear
    case tappedThread(threadRootEventID: String)
}
