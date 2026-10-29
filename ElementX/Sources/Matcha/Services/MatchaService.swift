//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

/// The Matcha features of one session. It keeps one `MatchaRoomStore` per room for every screen and window showing that room,
/// and hands out the Tasks tab's store of a chat the tab has open rather than reading the room a second time.
///
/// ponytail: only a board the Tasks tab already has open is shared with it; a chat opened before the tab finds its board, or
/// the tab finding the board of a chat already open, still reads the room twice, as on Android. Handing the chat's store to the
/// tab would lift that.
final class MatchaService {
    let tasksTabRooms: TasksTabRooms
    /// Opens the notes of a space; one notes engine, so one web view, for the whole session. The web view starts with the first note
    /// opened and goes when the last one closes.
    let notesContextFactory: SpaceNotesContextFactory
    /// The Notes tab's spaces and what it read of them, kept for the session.
    let notesTabReader: NotesTabReader
    /// The custom emoji packs of each room, kept for the session.
    let customEmojiPacks: CustomEmojiPacks
    private let noBoardAnswers: NoBoardAnswers
    private var stores = [String: Entry]()
    
    init(clientProxy: ClientProxyProtocol) {
        noBoardAnswers = NoBoardAnswers()
        tasksTabRooms = TasksTabRooms(clientProxy: clientProxy, noBoardAnswers: noBoardAnswers)
        notesContextFactory = SpaceNotesContextFactory(clientProxy: clientProxy, engine: WebViewYjsEngine())
        notesTabReader = NotesTabReader(clientProxy: clientProxy, contextFactory: notesContextFactory)
        customEmojiPacks = CustomEmojiPacks(clientProxy: clientProxy)
    }
    
    /// The store of `room`, opened unless a screen or the Tasks tab has it open; each call is matched by `releaseStore(_:)`.
    func acquireStore(for room: JoinedRoomProxyProtocol) -> MatchaRoomStore {
        if let entry = stores[room.id] {
            stores[room.id]?.holders += 1
            return entry.store
        }
        let tabRoom = tasksTabRooms.acquire(roomID: room.id)
        let store = tabRoom?.store ?? MatchaRoomStore(room: room, noBoardAnswers: noBoardAnswers)
        stores[room.id] = Entry(store: store, tabRoom: tabRoom, holders: 1)
        return store
    }
    
    /// Lets go of a store taken by `acquireStore(for:)`; the last one stops it, or hands it back to the Tasks tab.
    func releaseStore(_ store: MatchaRoomStore) {
        let roomID = store.room.id
        guard let entry = stores[roomID], entry.store === store else { return }
        guard entry.holders == 1 else {
            stores[roomID]?.holders -= 1
            return
        }
        stores[roomID] = nil
        if let tabRoom = entry.tabRoom {
            tasksTabRooms.release(tabRoom)
        } else {
            store.stop()
        }
    }
    
    /// Stops every store and the Notes tab's reads, on logout and when the cache is cleared.
    func stop() {
        notesTabReader.stop()
        for entry in stores.values {
            entry.store.stop()
            // The Tasks tab may be waiting for this hold before it lets go of the room.
            if let tabRoom = entry.tabRoom {
                tasksTabRooms.release(tabRoom)
            }
        }
        stores = [:]
        tasksTabRooms.stop()
    }
    
    // MARK: - Private
    
    private struct Entry {
        let store: MatchaRoomStore
        /// The Tasks tab's room, when the store is the tab's.
        let tabRoom: TabRoom?
        var holders: Int
    }
}
