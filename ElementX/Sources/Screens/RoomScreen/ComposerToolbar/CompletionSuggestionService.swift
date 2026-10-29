//
// Copyright 2025 Element Creations Ltd.
// Copyright 2023-2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation
import MatchaProtocol

private enum SuggestionTriggerRegex {
    /// Matches any string of characters after an @ or # that is not a whitespace
    static let atOrHash = /[@#]\S*/
    /// matcha: a custom emoji's `:code`, at the start or after whitespace, as in the web client's EmojiProvider.
    static let colon = /(?:^|\s)(:[^\s:]+:?)/
    
    static let at: Character = "@"
    static let hash: Character = "#"
}

final class CompletionSuggestionService: CompletionSuggestionServiceProtocol {
    private let roomProxy: JoinedRoomProxyProtocol
    private var canMentionAllUsers = false
    /// matcha: reads the room's custom emoji packs again; nil while custom emoji are off.
    private let loadCustomEmojiPacks: CustomEmojiPacksLoader?
    private let customEmojiPacksSubject = CurrentValueSubject<[EmojiPack], Never>([]) // matcha
    private var loadCustomEmojiPacksTask: Task<Void, Never>? // matcha
    
    private(set) var suggestionsPublisher: AnyPublisher<[SuggestionItem], Never> = Empty().eraseToAnyPublisher()
    
    private let suggestionTriggerSubject = CurrentValueSubject<SuggestionTrigger?, Never>(nil)
    
    private var cancellables = Set<AnyCancellable>()
    
    private var updateMembersTask: Task<Void, Never>?
    
    init(roomProxy: JoinedRoomProxyProtocol,
         roomListPublisher: AnyPublisher<[RoomSummary], Never>,
         loadCustomEmojiPacks: CustomEmojiPacksLoader? = nil) { // matcha: loadCustomEmojiPacks
        self.roomProxy = roomProxy
        self.loadCustomEmojiPacks = loadCustomEmojiPacks // matcha
        
        suggestionsPublisher = suggestionTriggerSubject
            .combineLatest(roomProxy.membersPublisher, roomListPublisher, customEmojiPacksSubject) // matcha: packs
            .map { [weak self, ownUserID = roomProxy.ownUserID] suggestionTrigger, members, roomSummaries, customEmojiPacks -> [SuggestionItem] in
                guard let self,
                      let suggestionTrigger else {
                    return []
                }
                
                switch suggestionTrigger.type {
                case .user:
                    return membersSuggestions(suggestionTrigger: suggestionTrigger, members: members, ownUserID: ownUserID)
                case .room:
                    return roomSuggestions(suggestionTrigger: suggestionTrigger, roomSummaries: roomSummaries)
                case .customEmoji: // matcha
                    return Self.customEmojiSuggestions(suggestionTrigger: suggestionTrigger, packs: customEmojiPacks)
                }
            }
            // We only debounce if the suggestion is nil
            .debounceAndRemoveDuplicates(on: DispatchQueue.main) { [weak self] _ in
                self?.suggestionTriggerSubject.value != nil ? .milliseconds(500) : .milliseconds(0)
            }
        
        roomProxy.infoPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] roomInfo in
                self?.updateRoomInfo(roomInfo)
            }
            .store(in: &cancellables)
        
        updateRoomInfo(roomProxy.infoPublisher.value)
    }
    
    func processTextMessage(_ textMessage: String, selectedRange: NSRange) {
        setSuggestionTrigger(detectTriggerInText(textMessage, selectedRange: selectedRange))
    }
    
    func setSuggestionTrigger(_ suggestionTrigger: SuggestionTrigger?) {
        let isNewUserMention = suggestionTrigger?.type == .user && suggestionTriggerSubject.value?.type != .user
        let isNewCustomEmoji = suggestionTrigger?.type == .customEmoji && suggestionTriggerSubject.value?.type != .customEmoji // matcha
        
        suggestionTriggerSubject.value = suggestionTrigger
        
        if isNewCustomEmoji { // matcha
            reloadCustomEmojiPacks()
        }
        
        // Refresh the members each time a new user suggestion is triggered to pull in the latest profiles.
        guard isNewUserMention, updateMembersTask == nil else { return }
        
        updateMembersTask = Task { [weak self, roomProxy] in
            await roomProxy.updateMembers()
            self?.updateMembersTask = nil
        }
    }
    
    // MARK: - Private
    
    private func updateRoomInfo(_ roomInfo: RoomInfoProxyProtocol) {
        if let powerLevels = roomInfo.powerLevels {
            canMentionAllUsers = powerLevels.canOwnUserTriggerRoomNotification()
        }
    }
    
    private func membersSuggestions(suggestionTrigger: SuggestionTrigger,
                                    members: [RoomMemberProxyProtocol],
                                    ownUserID: String) -> [SuggestionItem] {
        var membersSuggestion = members
            .compactMap { member -> SuggestionItem? in
                guard member.userID != ownUserID,
                      member.membership == .join,
                      Self.shouldIncludeMember(userID: member.userID, displayName: member.displayName, searchText: suggestionTrigger.text) else {
                    return nil
                }
                return .init(suggestionType: .user(.init(id: member.userID, displayName: member.displayName, avatarURL: member.avatarURL, status: member.status)),
                             range: suggestionTrigger.range, rawSuggestionText: suggestionTrigger.text)
            }
        
        if canMentionAllUsers,
           !roomProxy.infoPublisher.value.isDM,
           Self.shouldIncludeMember(userID: PillUtilities.atRoom, displayName: PillUtilities.everyone, searchText: suggestionTrigger.text) {
            membersSuggestion
                .insert(SuggestionItem(suggestionType: .allUsers(roomProxy.details.avatar), range: suggestionTrigger.range, rawSuggestionText: suggestionTrigger.text), at: 0)
        }
        
        return membersSuggestion
    }
    
    private func roomSuggestions(suggestionTrigger: SuggestionTrigger,
                                 roomSummaries: [RoomSummary]) -> [SuggestionItem] {
        roomSummaries
            .compactMap { roomSummary -> SuggestionItem? in
                guard let canonicalAlias = roomSummary.canonicalAlias,
                      Self.shouldIncludeRoom(roomName: roomSummary.name, roomAlias: canonicalAlias, searchText: suggestionTrigger.text) else {
                    return nil
                }
                
                return .init(suggestionType: .room(.init(id: roomSummary.id,
                                                         canonicalAlias: canonicalAlias,
                                                         name: roomSummary.name,
                                                         avatar: roomSummary.avatar)),
                             range: suggestionTrigger.range, rawSuggestionText: suggestionTrigger.text)
            }
    }
    
    private func detectTriggerInText(_ text: String, selectedRange: NSRange) -> SuggestionTrigger? {
        let matches = text.matches(of: SuggestionTriggerRegex.atOrHash)
        let match = matches.first { matchResult in
            let lowerBound = matchResult.range.lowerBound.utf16Offset(in: matchResult.base)
            let upperBound = matchResult.range.upperBound.utf16Offset(in: matchResult.base)
            return selectedRange.location >= lowerBound
                && selectedRange.location <= upperBound
                && selectedRange.length <= upperBound - lowerBound
        }
        
        guard let match else {
            return customEmojiTrigger(in: text, selectedRange: selectedRange) // matcha
        }
        
        var suggestionText = String(text[match.range])
        let firstChar = suggestionText.removeFirst()
        
        switch firstChar {
        case SuggestionTriggerRegex.at:
            return .init(type: .user, text: suggestionText, range: NSRange(match.range, in: text))
        case SuggestionTriggerRegex.hash:
            return .init(type: .room, text: suggestionText, range: NSRange(match.range, in: text))
        default:
            return nil
        }
    }
    
    private static func shouldIncludeMember(userID: String, displayName: String?, searchText: String) -> Bool {
        // If the search text is empty give back all the results
        guard !searchText.isEmpty else {
            return true
        }
        let containedInUserID = userID.localizedStandardContains(searchText)
        
        let containedInDisplayName: Bool
        if let displayName {
            containedInDisplayName = displayName.localizedStandardContains(searchText)
        } else {
            containedInDisplayName = false
        }
        
        return containedInUserID || containedInDisplayName
    }
    
    private static func shouldIncludeRoom(roomName: String, roomAlias: String, searchText: String) -> Bool {
        // If the search text is empty give back all the results
        guard !searchText.isEmpty else {
            return true
        }
        return roomName.localizedStandardContains(searchText) || roomAlias.localizedStandardContains(searchText)
    }
}

// MARK: - Matcha

private extension CompletionSuggestionService {
    /// Custom emoji whose shortcode starts with the typed `:code`, as the web client offers them.
    static func customEmojiSuggestions(suggestionTrigger: SuggestionTrigger, packs: [EmojiPack]) -> [SuggestionItem] {
        ImagePacks.suggestions(for: suggestionTrigger.text, in: packs).map { emoji in
            SuggestionItem(suggestionType: .customEmoji(emoji), range: suggestionTrigger.range, rawSuggestionText: suggestionTrigger.text)
        }
    }
    
    /// The `:code` being typed, when custom emoji are on: a colon at the start or after whitespace, then at least one character.
    func customEmojiTrigger(in text: String, selectedRange: NSRange) -> SuggestionTrigger? {
        guard loadCustomEmojiPacks != nil else { return nil }
        for match in text.matches(of: SuggestionTriggerRegex.colon) {
            let code = match.output.1
            let range = NSRange(code.startIndex..<code.endIndex, in: text)
            if selectedRange.location >= range.lowerBound, selectedRange.location <= range.upperBound, selectedRange.length <= range.length {
                return SuggestionTrigger(type: .customEmoji, text: String(code.dropFirst()), range: range)
            }
        }
        return nil
    }
    
    /// Reads the room's packs again each time suggestions open, so they follow edits made elsewhere.
    func reloadCustomEmojiPacks() {
        guard let loadCustomEmojiPacks, loadCustomEmojiPacksTask == nil else { return }
        loadCustomEmojiPacksTask = Task { [weak self] in
            let packs = await loadCustomEmojiPacks()
            self?.customEmojiPacksSubject.send(packs)
            self?.loadCustomEmojiPacksTask = nil
        }
    }
}

extension PillUtilities {
    static var everyone: String {
        L10n.commonEveryone
    }
}
