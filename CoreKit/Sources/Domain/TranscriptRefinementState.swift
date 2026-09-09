import Foundation

public enum TranscriptVersion: String, Sendable, Hashable, Codable {
    case native, refined
}

/// FR17.18: the immutable source of one confirmation, independent of its extracted fields/target.
public struct TranscriptSourceSnapshot: Sendable, Equatable, Codable {
    public let sessionID: UUID
    public let generation: UInt64
    public let authorizationGeneration: UInt64
    public let nativeText: String
    public let selectedText: String
    public let version: TranscriptVersion

    public var requiresOriginalPersistence: Bool {
        !nativeText.utf8.elementsEqual(selectedText.utf8)
    }
}

/// SP-55 source identity and formatting selection; no audio/session-engine ownership.
public struct TranscriptRefinementState: Sendable {
    public private(set) var nativeText = ""
    public private(set) var generation: UInt64 = 0
    public private(set) var version: TranscriptVersion = .native
    public private(set) var revision: TranscriptRevision?
    public private(set) var isRefining = false
    private let sessionID = UUID()
    private var appendHistory: [Int] = []
    private var revisionAuthorizationGeneration: UInt64?

    public init() {}

    public var canClearLast: Bool { !appendHistory.isEmpty }

    public mutating func edit(_ text: String) {
        guard !nativeText.utf8.elementsEqual(text.utf8) else { return }
        nativeText = text
        // Whole-text editing invalidates recording boundaries, never the edited text itself.
        appendHistory = []
        invalidate()
    }

    public mutating func append(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        appendHistory.append(nativeText.utf8.count)
        nativeText = nativeText.isEmpty ? text : nativeText + "\n" + text
        invalidate()
    }

    @discardableResult
    public mutating func clearLast() -> Bool {
        guard let prefixLength = appendHistory.popLast() else { return false }
        nativeText = String(decoding: nativeText.utf8.prefix(prefixLength), as: UTF8.self)
        invalidate()
        return true
    }

    public mutating func clearAll() {
        nativeText = ""
        appendHistory = []
        version = .native
        invalidate()
    }

    public mutating func select(_ selection: TranscriptVersion, authorized: Bool) {
        let selection: TranscriptVersion = authorized ? selection : .native
        guard version != selection else { return }
        version = selection
        invalidate()
    }

    public mutating func revokeAI() {
        guard version != .native || revision != nil || isRefining else { return }
        version = .native
        invalidate()
    }

    public mutating func cancelRefinement() {
        guard isRefining else { return }
        invalidate()
    }

    public mutating func beginRefinement(authorized: Bool, authorizationGeneration: UInt64) -> TranscriptSourceSnapshot? {
        guard authorized, version == .refined,
              !nativeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !EmergencyKeywordRules.match(nativeText) else { return nil }
        invalidate()
        isRefining = true
        return snapshot(authorized: authorized, authorizationGeneration: authorizationGeneration)
    }

    @discardableResult
    public mutating func publish(_ result: TranscriptRevision, for request: TranscriptSourceSnapshot,
                                 authorized: Bool, authorizationGeneration: UInt64) -> Bool {
        guard authorized else { revokeAI(); return false }
        guard isRefining, version == .refined, request.sessionID == sessionID,
              request.generation == generation,
              request.nativeText.utf8.elementsEqual(nativeText.utf8) else { return false }
        guard request.authorizationGeneration == authorizationGeneration else { revokeAI(); return false }
        isRefining = false
        generation += 1
        guard result.original.utf8.elementsEqual(nativeText.utf8) else {
            revision = .unavailable(nativeText)
            return false
        }
        revision = result
        revisionAuthorizationGeneration = authorizationGeneration
        return true
    }

    public func snapshot(authorized: Bool, authorizationGeneration: UInt64) -> TranscriptSourceSnapshot {
        let useSuggestion = authorized && version == .refined && revision?.safety == .accepted
            && revisionAuthorizationGeneration == authorizationGeneration
            && revision?.original.utf8.elementsEqual(nativeText.utf8) == true
        return TranscriptSourceSnapshot(sessionID: sessionID, generation: generation,
                                        authorizationGeneration: authorizationGeneration,
                                        nativeText: nativeText,
                                        selectedText: useSuggestion ? (revision?.suggested ?? nativeText) : nativeText,
                                        version: useSuggestion ? .refined : .native)
    }

    public func matches(_ source: TranscriptSourceSnapshot, authorized: Bool, authorizationGeneration: UInt64) -> Bool {
        let current = snapshot(authorized: authorized, authorizationGeneration: authorizationGeneration)
        return source.sessionID == sessionID && source.generation == generation
            && (source.version == .native || source.authorizationGeneration == authorizationGeneration)
            && source.version == current.version
            && source.nativeText.utf8.elementsEqual(current.nativeText.utf8)
            && source.selectedText.utf8.elementsEqual(current.selectedText.utf8)
    }

    public func canCommit(_ source: TranscriptSourceSnapshot, authorized: Bool, authorizationGeneration: UInt64,
                          preservesOriginal: Bool) -> Bool {
        matches(source, authorized: authorized, authorizationGeneration: authorizationGeneration)
            && (!source.requiresOriginalPersistence || preservesOriginal)
    }

    @discardableResult
    public mutating func finishCommit(_ source: TranscriptSourceSnapshot, authorized: Bool, authorizationGeneration: UInt64,
                                      succeeded: Bool) -> Bool {
        guard succeeded, canCommit(source, authorized: authorized, authorizationGeneration: authorizationGeneration,
                                   preservesOriginal: false) else { return false }
        clearAll()
        return true
    }

    private mutating func invalidate() {
        generation += 1
        revision = nil
        revisionAuthorizationGeneration = nil
        isRefining = false
    }
}
