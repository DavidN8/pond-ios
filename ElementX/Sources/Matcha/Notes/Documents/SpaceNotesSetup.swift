//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatchaProtocol

/// Whether a space's notes are turned on, and whether this user may turn them on.
struct SpaceNotesStatus: Equatable {
    var isConfigured: Bool
    var canSetUp: Bool
    var isEncrypted: Bool
    
    /// Reads the status from the space's stored `m.room.encryption` and `m.room.power_levels` contents and its info.
    init(encryptionJSON: String?, powerLevelsJSON: String?, info: RoomInfoProxyProtocol) {
        let algorithm = encryptionJSON.flatMap(JSONValue.init(json:))?.objectValue?.string("algorithm")
        let events = powerLevelsJSON.flatMap(JSONValue.init(json:))?.objectValue?.object("events")
        // Only a space: in a chat, these power levels would let every member post anything encrypted.
        let isJoinedSpace = info.isSpace && info.membership == .joined
        isConfigured = isJoinedSpace && algorithm == DocsProtocol.encryptionAlgorithm
            && events?.integer(MatchaConfig.eventDocsUpdate) == 0 && events?.integer(DocsProtocol.eventRoomEncrypted) == 0
        canSetUp = isJoinedSpace && info.powerLevels.map { $0.canOwnUser(sendStateEvent: .roomEncryption) && $0.canOwnUser(sendStateEvent: .roomPowerLevels) } == true
        isEncrypted = algorithm != nil || info.isEncrypted
    }
    
    init(isConfigured: Bool, canSetUp: Bool, isEncrypted: Bool) {
        self.isConfigured = isConfigured
        self.canSetUp = canSetUp
        self.isEncrypted = isEncrypted
    }
}

nonisolated enum SpaceNotesSetupError: Error {
    case notAllowed
    case unsupportedEncryption
    case noPowerLevels
    case notSynced
    case room(RoomProxyError)
}

/// The one-time setup that lets every member of a space write notes, like the web client's `SpaceDocsViewModel`: encryption on
/// with Megolm, and the power levels of `com.matchahoneylatte.docs.update` and `m.room.encrypted` at 0. Child rooms never change.
struct SpaceNotesSetup {
    let room: JoinedRoomProxyProtocol
    
    /// Whether the space's notes are on, from its stored state only.
    func status() async -> SpaceNotesStatus {
        await SpaceNotesStatus(encryptionJSON: stateContent("m.room.encryption"),
                               powerLevelsJSON: stateContent(DocsProtocol.eventPowerLevels),
                               info: room.infoPublisher.value)
    }
    
    /// Turns encryption on if needed, then sets only the two power levels, waiting for each change to sync.
    func turnOn() async -> Result<Void, SpaceNotesSetupError> {
        let result = await performTurnOn()
        if case .failure(let error) = result {
            MXLog.warning("Could not turn on space notes: \(error)")
        }
        return result
    }
    
    // MARK: - Private
    
    private func performTurnOn() async -> Result<Void, SpaceNotesSetupError> {
        guard await status().canSetUp else { return .failure(.notAllowed) }
        let currentAlgorithm = await algorithm()
        if let currentAlgorithm, currentAlgorithm != DocsProtocol.encryptionAlgorithm {
            return .failure(.unsupportedEncryption)
        }
        if currentAlgorithm == nil {
            if case .failure(let error) = await room.enableEncryption() {
                return .failure(.room(error))
            }
            guard await awaitSynced({ await algorithm() == DocsProtocol.encryptionAlgorithm }) else { return .failure(.notSynced) }
        }
        // Read the power levels fresh, right before changing them, so nobody else's change is lost.
        guard var powerLevels = await stateContent(DocsProtocol.eventPowerLevels).flatMap(JSONValue.init(json:))?.objectValue else {
            return .failure(.noPowerLevels)
        }
        var events = powerLevels.object("events") ?? [:]
        events[MatchaConfig.eventDocsUpdate] = .integer(0)
        events[DocsProtocol.eventRoomEncrypted] = .integer(0)
        powerLevels["events"] = .object(events)
        if case .failure(let error) = await room.sendRawStateEvent(type: DocsProtocol.eventPowerLevels, stateKey: "", contentJSON: JSONValue.object(powerLevels).jsonString) {
            return .failure(.room(error))
        }
        return await awaitSynced { await status().isConfigured } ? .success(()) : .failure(.notSynced)
    }
    
    private func algorithm() async -> String? {
        await stateContent("m.room.encryption").flatMap(JSONValue.init(json:))?.objectValue?.string("algorithm")
    }
    
    private func stateContent(_ type: String) async -> String? {
        try? await room.stateEventsJSON(type: type).get()[""]
    }
    
    /// State changes arrive with syncs, and the room info doesn't change for every one (power levels don't always change it), so
    /// the stored state is checked twice a second until `isDone` or 20 seconds have passed.
    private func awaitSynced(_ isDone: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if await isDone() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }
}
