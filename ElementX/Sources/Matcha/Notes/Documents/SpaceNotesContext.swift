//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatchaProtocol

/// What the notes screens of one space share while they are open: the space, its Matcha store (whose frames the documents read)
/// and the catalog of names. For a chat's earlier document there is no catalog and everything is read-only.
final class SpaceNotesContext {
    let room: JoinedRoomProxyProtocol
    let store: MatchaRoomStore
    let catalog: DocumentCatalog?
    /// Whether the homeserver can be reached, for the offline notices.
    let reachability: CurrentValuePublisher<HomeserverReachability, Never>
    private let catalogSession: RoomDocumentSession?
    private let makeSession: (_ documentID: String) -> RoomDocumentSession
    private var isClosed = false
    
    /// The chat's own earlier document, read-only, instead of a space's notes.
    var isEarlierChatDocument: Bool {
        catalog == nil
    }
    
    init(room: JoinedRoomProxyProtocol,
         store: MatchaRoomStore,
         reachability: CurrentValuePublisher<HomeserverReachability, Never>,
         catalogSession: RoomDocumentSession?,
         catalog: DocumentCatalog?,
         makeSession: @escaping (_ documentID: String) -> RoomDocumentSession) {
        self.room = room
        self.store = store
        self.reachability = reachability
        self.catalogSession = catalogSession
        self.catalog = catalog
        self.makeSession = makeSession
    }
    
    /// A new session for one document; close it when its screen goes away.
    func openDocument(_ documentID: String) -> RoomDocumentSession {
        makeSession(documentID)
    }
    
    func close() {
        guard !isClosed else { return }
        isClosed = true
        catalogSession?.close()
        store.stop()
    }
}

/// Opens the notes of a space, or the earlier document of a chat, each with a Matcha store of its own that also reads the events
/// related to the room's `m.room.create` event.
struct SpaceNotesContextFactory {
    let clientProxy: ClientProxyProtocol
    let engine: YjsEngineProtocol
    var newDocumentID: () -> String = { UUID().uuidString.lowercased() }
    
    /// Nil when the room is not joined, or is not a space while a space's notes are asked for.
    func makeContext(roomID: String, isEarlierChatDocument: Bool = false) async -> SpaceNotesContext? {
        guard case .joined(let room) = await clientProxy.roomForIdentifier(roomID) else { return nil }
        // Like the web client: a chat never gets a catalog, editable notes or the notes power levels.
        guard isEarlierChatDocument || room.infoPublisher.value.isSpace else { return nil }
        let store = MatchaRoomStore(room: room, noBoardAnswers: NoBoardAnswers(), readsDocumentAnchor: true)
        let reachability = clientProxy.homeserverReachabilityPublisher
        let engine = engine
        let makeSession = { (documentID: String) in
            RoomDocumentSession(documentID: documentID,
                                room: room,
                                store: store,
                                engine: engine,
                                reachability: reachability,
                                isReadOnly: isEarlierChatDocument)
        }
        let catalogSession = isEarlierChatDocument ? nil : makeSession(DocsProtocol.catalogDocumentID)
        return SpaceNotesContext(room: room,
                                 store: store,
                                 reachability: reachability,
                                 catalogSession: catalogSession,
                                 catalog: catalogSession.map { DocumentCatalog(session: $0, room: room, newDocumentID: newDocumentID) },
                                 makeSession: makeSession)
    }
}
