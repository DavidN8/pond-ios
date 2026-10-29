//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatchaProtocol

nonisolated struct CatalogState: Equatable, Sendable {
    var documents: [SpaceDocument] = []
    var isReady = false
    var canEdit = false
    var sync = DocumentSync.loading
    var pendingUpdates = 0
    var error: DocumentError?
    
    /// The catalog failed in a way that leaves nothing to show, only Retry.
    var isLoadFailed: Bool {
        switch error {
        case .loadError, .anchorError, .invalidUpdate: true
        default: false
        }
    }
    
    static let loading = CatalogState()
}

/// A catalog write failed. When only the save of a new note failed, `documentID` names the entry kept locally, so a retry renames
/// it instead of adding another.
nonisolated struct CatalogError: Error, Equatable {
    let error: DocumentError
    var documentID: String?
}

/// The encrypted list of a space's note names, kept in the reserved `catalog` document like the web client's
/// `SpaceDocumentCatalog`. Names are written only when the space is encrypted.
final class DocumentCatalog {
    private let session: RoomDocumentSession
    private let room: JoinedRoomProxyProtocol
    private let clock: () -> Int64
    private let newDocumentID: () -> String
    
    private let stateSubject: CurrentValueSubject<CatalogState, Never>
    var statePublisher: CurrentValuePublisher<CatalogState, Never> {
        stateSubject.asCurrentValuePublisher()
    }
    
    var state: CatalogState {
        stateSubject.value
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    init(session: RoomDocumentSession,
         room: JoinedRoomProxyProtocol,
         clock: @escaping () -> Int64 = { Int64(Date.now.timeIntervalSince1970 * 1000) },
         newDocumentID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.session = session
        self.room = room
        self.clock = clock
        self.newDocumentID = newDocumentID
        stateSubject = .init(Self.catalogState(session.state, isEncrypted: room.infoPublisher.value.isEncrypted))
        
        session.statePublisher
            .combineLatest(room.infoPublisher.map(\.isEncrypted).removeDuplicates())
            .map(Self.catalogState)
            .removeDuplicates()
            .sink { [weak self] in self?.stateSubject.send($0) }
            .store(in: &cancellables)
    }
    
    /// Publishes a new named note; returns its id once its catalog entry is acknowledged.
    func create(title: String) async -> Result<String, CatalogError> {
        if let error = checkWrite(title) {
            return .failure(error)
        }
        let documentID = newDocumentID()
        switch await write(documentID: documentID, title: title.kotlinTrimmed, createdAt: clock()) {
        case .success:
            return .success(documentID)
        case .failure(var error):
            if session.state.pendingUpdates > 0 {
                error.documentID = documentID
            }
            return .failure(error)
        }
    }
    
    /// Renames a note's catalog entry, without touching its text.
    func rename(documentID: String, title: String) async -> Result<Void, CatalogError> {
        if let error = checkWrite(title) {
            return .failure(error)
        }
        guard let entry = currentState.documents.first(where: { $0.id == documentID }) else { return .failure(.init(error: .invalidUpdate)) }
        if entry.title == title.kotlinTrimmed {
            return await save()
        }
        return await write(documentID: documentID, title: title.kotlinTrimmed, createdAt: entry.createdAt)
    }
    
    /// Recovers missing history or keys, and retries the unsent names.
    func retry() async {
        await session.retry().value
        await session.flush()
    }
    
    // MARK: - Private
    
    /// The state right now: the published one can lag behind the session by a run loop.
    private var currentState: CatalogState {
        Self.catalogState(session.state, isEncrypted: room.infoPublisher.value.isEncrypted)
    }
    
    private func write(documentID: String, title: String, createdAt: Int64) async -> Result<Void, CatalogError> {
        let value: JSONObject = ["title": .string(title), "createdAt": .integer(createdAt)]
        guard await session.setEntry(key: documentID, value: value) else {
            return .failure(.init(error: session.state.error ?? .permissionError))
        }
        return await save()
    }
    
    private func save() async -> Result<Void, CatalogError> {
        await session.flush()
        let state = session.state
        if state.error != nil || state.pendingUpdates > 0 {
            return .failure(.init(error: state.error ?? .sendError))
        }
        return .success(())
    }
    
    private func checkWrite(_ title: String) -> CatalogError? {
        guard DocsProtocol.isValidName(title) else { return .init(error: .invalidUpdate) }
        let state = currentState
        return state.canEdit ? nil : .init(error: state.error ?? .permissionError)
    }
    
    private nonisolated static func catalogState(_ state: DocumentSessionState, isEncrypted: Bool) -> CatalogState {
        let catalog = DocsProtocol.catalogDocuments(state.entries)
        return CatalogState(documents: catalog.documents,
                            isReady: state.isReady && !catalog.isInvalid,
                            canEdit: state.canEdit && !catalog.isInvalid && isEncrypted,
                            sync: catalog.isInvalid ? .error : state.sync,
                            pendingUpdates: state.pendingUpdates,
                            error: catalog.isInvalid ? .invalidUpdate : state.error)
    }
}
