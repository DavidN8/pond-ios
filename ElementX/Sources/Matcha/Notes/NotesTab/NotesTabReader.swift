//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatchaProtocol

/// A joined space as the Notes tab lists it, with what is known about its notes.
nonisolated struct NotesSpace: Equatable, Sendable {
    let id: String
    let name: String
    /// For a subspace, the name of the top-level space it is listed under.
    let parentName: String?
    let avatarURL: URL?
    let notes: SpaceNotes
}

/// What the Notes tab knows about the notes of a space.
nonisolated enum SpaceNotes: Equatable, Sendable {
    /// Not checked yet.
    case unknown
    /// Notes are off and the user can't turn them on.
    case off
    /// Notes are off and the user can turn them on.
    case canTurnOn
    case on(SpaceNotesRead)
}

nonisolated struct SpaceNotesRead: Equatable, Sendable {
    /// The last catalog read, kept once the space is closed; nil until one has been read.
    var catalog: CatalogState?
    /// When each note was last edited, from the same read.
    var lastEdits: [String: Int64] = [:]
    /// The catalog could not be opened or read; `NotesTabReader.retry(spaceID:)` reads it again.
    var isFailed = false
}

/// The notes of every joined space, for the Notes tab, as Android's `NotesTabReader`. The spaces come from the space service's
/// space filters, as the space filter picker lists them: each top-level space in the order of the Spaces list, followed by its
/// joined subspaces. Whether each has notes is checked from its stored state, a few at a time, without opening its timeline.
///
/// A space's catalog is expensive to read: it is a Yjs document replayed from the space's history, which takes a Matcha store and an
/// engine document. So between `start()` and `stop()` only the catalogs of the spaces on screen (`setShown(_:)`) are read, a few at a
/// time; each stays open while its space stays on screen and closes `closeDelay` after it scrolls away, and `stop()` closes every
/// one. What was read is kept for the session, so the tab shows it at once when it comes back.
///
/// ponytail: a closed catalog is read in full again each time its space comes back on screen, and setup is checked again for every
/// space each time the tab starts. Only the two levels the space filters hold are listed: a joined space below a subspace is reached
/// from its parent's screen.
final class NotesTabReader {
    private nonisolated struct JoinedSpace: Equatable {
        let id: String
        let name: String
        let parentName: String?
        let avatarURL: URL?
    }
    
    private let clientProxy: ClientProxyProtocol
    private let contextFactory: SpaceNotesContextFactory
    private let closeDelay: Duration
    private let loadTimeout: Duration
    
    private let spacesSubject = CurrentValueSubject<[NotesSpace]?, Never>(nil)
    /// The joined spaces, each top-level one followed by its subspaces, or nil until the space service has listed them.
    var spacesPublisher: CurrentValuePublisher<[NotesSpace]?, Never> {
        spacesSubject.asCurrentValuePublisher()
    }
    
    private var joined: [JoinedSpace]?
    private var notes: [String: SpaceNotes] = [:]
    private var shown = Set<String>()
    private var isRunning = false
    private var spacesCancellable: AnyCancellable?
    private var checked = Set<String>()
    private var checkTasks: [String: Task<Void, Never>] = [:]
    private var readTasks: [String: Task<Void, Never>] = [:]
    private var closeTasks: [String: Task<Void, Never>] = [:]
    private let checks = TaskLimiter(limit: NotesTabReader.maxConcurrentReads)
    private let reads = TaskLimiter(limit: NotesTabReader.maxConcurrentReads)
    
    init(clientProxy: ClientProxyProtocol,
         contextFactory: SpaceNotesContextFactory,
         closeDelay: Duration = .seconds(20),
         loadTimeout: Duration = NotesTabReader.loadTimeout) {
        self.clientProxy = clientProxy
        self.contextFactory = contextFactory
        self.closeDelay = closeDelay
        self.loadTimeout = loadTimeout
    }
    
    /// Follows the joined spaces and reads the catalogs on screen until `stop()`.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        // ponytail: the space filters start empty without saying whether they are listed yet, so no filter means no space only once the
        // room list has loaded. A first sync can still list the rooms a moment before the space service has read them.
        spacesCancellable = clientProxy.spaceService.spaceFilterPublisher
            .combineLatest(clientProxy.staticRoomSummaryProvider.statePublisher.map(\.isLoaded).removeDuplicates())
            .compactMap { filters, isRoomListLoaded in
                filters.isEmpty && !isRoomListLoaded ? nil : Self.joinedSpaces(filters)
            }
            .removeDuplicates()
            .sink { [weak self] in self?.update(joined: $0) }
    }
    
    /// Stops following the spaces and closes every catalog this reader opened; what was read stays.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        spacesCancellable = nil
        shown = []
        checked = []
        for task in Array(checkTasks.values) + Array(readTasks.values) + Array(closeTasks.values) {
            task.cancel()
        }
        checkTasks = [:]
        readTasks = [:]
        closeTasks = [:]
    }
    
    /// The spaces on screen: only their catalogs are read.
    func setShown(_ spaceIDs: Set<String>) {
        shown = spaceIDs
        updateReads()
    }
    
    /// Reads again the catalog of a space whose read failed.
    func retry(spaceID: String) {
        updateOn(spaceID) { read in
            read.catalog = nil
            read.isFailed = false
        }
    }
    
    // MARK: - Private
    
    /// Each top-level space (level 0) followed by its joined subspaces (the level 1 filters after it).
    private nonisolated static func joinedSpaces(_ filters: [SpaceServiceFilter]) -> [JoinedSpace] {
        var parentName: String?
        var listed = Set<String>()
        return filters.compactMap { filter in
            let room = filter.room
            if filter.level == 0 {
                parentName = room.name
            }
            // A space's children are listed whatever the user's membership of them; a subspace of several spaces is listed under the first.
            guard room.state == .joined, listed.insert(room.id).inserted else { return nil }
            return JoinedSpace(id: room.id, name: room.name, parentName: filter.level > 0 ? parentName : nil, avatarURL: room.avatarURL)
        }
    }
    
    private func update(joined spaces: [JoinedSpace]) {
        let spaceIDs = Set(spaces.map(\.id))
        joined = spaces
        notes = notes.filter { spaceIDs.contains($0.key) }
        checked.formIntersection(spaceIDs)
        for spaceID in spaceIDs.subtracting(checked) {
            checked.insert(spaceID)
            checkTasks[spaceID] = Task { [weak self] in await self?.check(spaceID) }
        }
        publish()
    }
    
    /// Whether the space has notes on, from its stored state. A space that can't be checked counts as off until the next start.
    private func check(_ spaceID: String) async {
        let status = await checks.run { () async -> SpaceNotesStatus? in
            guard !Task.isCancelled else { return nil }
            return await readStatus(spaceID)
        }
        guard !Task.isCancelled else { return }
        checkTasks[spaceID] = nil
        if let status, status.isConfigured {
            // What was read before stays until the catalog is read again; a failed read is tried again.
            var read = if case .on(let previous) = notes[spaceID] {
                previous
            } else {
                SpaceNotesRead()
            }
            read.isFailed = false
            notes[spaceID] = .on(read)
        } else {
            notes[spaceID] = status?.canSetUp == true ? .canTurnOn : .off
        }
        publish()
    }
    
    private func readStatus(_ spaceID: String) async -> SpaceNotesStatus? {
        switch await clientProxy.roomInfo(roomID: spaceID) {
        case .success(let info):
            let encryption = try? await clientProxy.stateEventsJSON(roomID: spaceID, type: "m.room.encryption").get()[""]
            let powerLevels = try? await clientProxy.stateEventsJSON(roomID: spaceID, type: DocsProtocol.eventPowerLevels).get()[""]
            return SpaceNotesStatus(encryptionJSON: encryption, powerLevelsJSON: powerLevels, info: info)
        case .failure(let error):
            MXLog.warning("Could not check the notes of \(spaceID): \(error)")
            return nil
        }
    }
    
    /// Starts reading the spaces on screen whose notes are on, and lets go of the others once they have been away for `closeDelay`.
    private func updateReads() {
        guard isRunning else { return }
        let wanted = shown.filter { spaceID in
            guard case .on(let read) = notes[spaceID] else { return false }
            return !read.isFailed
        }
        for spaceID in wanted {
            closeTasks.removeValue(forKey: spaceID)?.cancel()
            if readTasks[spaceID] == nil {
                readTasks[spaceID] = Task { [weak self] in await self?.read(spaceID) }
            }
        }
        // A space that scrolls away briefly keeps its catalog; one that stays away lets it go.
        for spaceID in Set(readTasks.keys).subtracting(wanted).subtracting(closeTasks.keys) {
            closeTasks[spaceID] = Task { [weak self, closeDelay] in
                try? await Task.sleep(for: closeDelay)
                guard !Task.isCancelled, let self else { return }
                readTasks.removeValue(forKey: spaceID)?.cancel()
                closeTasks[spaceID] = nil
            }
        }
    }
    
    /// Opens the space's catalog and follows it until cancelled or until it fails to load, then closes it.
    private func read(_ spaceID: String) async {
        var context: SpaceNotesContext?
        var catalog: DocumentCatalog?
        var following: AnyCancellable?
        defer {
            following?.cancel()
            context?.close()
        }
        await reads.run {
            guard !Task.isCancelled else { return }
            context = await contextFactory.makeContext(roomID: spaceID)
            guard let context, let opened = context.catalog else { return }
            catalog = opened
            following = follow(spaceID, store: context.store, catalog: opened)
            // The turn is kept while the catalog replays the space's history, so only a few spaces read at once.
            _ = await firstValue(of: opened.statePublisher, timeout: loadTimeout) { $0.sync != .loading }
        }
        guard !Task.isCancelled else { return }
        if let catalog {
            _ = await firstValue(of: catalog.statePublisher) { $0.isLoadFailed }
        } else {
            MXLog.warning("Could not open the notes of \(spaceID)")
            updateOn(spaceID) { $0.isFailed = true }
        }
        // Cancelled, the task was already let go of; failed, it lets go of itself so Retry can read again.
        if !Task.isCancelled {
            readTasks[spaceID] = nil
        }
    }
    
    /// Keeps what the catalog shows; a catalog read again starts empty, so what was read before is shown until the new read is done.
    private func follow(_ spaceID: String, store: MatchaRoomStore, catalog: DocumentCatalog) -> AnyCancellable {
        catalog.statePublisher
            .combineLatest(store.snapshotPublisher.map { NoteRowItem.lastEdits($0.events) }.removeDuplicates())
            .sink { [weak self] state, edits in
                guard let self else { return }
                updateOn(spaceID) { read in
                    if state.sync != .loading || read.catalog == nil {
                        read.catalog = state
                        read.lastEdits = edits
                    }
                    read.isFailed = state.isLoadFailed
                }
                if state.isLoadFailed {
                    MXLog.warning("Could not load the notes of \(spaceID)")
                }
            }
    }
    
    private func updateOn(_ spaceID: String, _ change: (inout SpaceNotesRead) -> Void) {
        guard case .on(var read) = notes[spaceID] else { return }
        change(&read)
        notes[spaceID] = .on(read)
        publish()
    }
    
    private func publish() {
        let spaces = joined?.map { NotesSpace(id: $0.id, name: $0.name, parentName: $0.parentName, avatarURL: $0.avatarURL, notes: notes[$0.id] ?? .unknown) }
        if spaces != spacesSubject.value {
            spacesSubject.send(spaces)
        }
        updateReads()
    }
    
    static let maxConcurrentReads = 3
    static let loadTimeout: Duration = .seconds(30)
}
