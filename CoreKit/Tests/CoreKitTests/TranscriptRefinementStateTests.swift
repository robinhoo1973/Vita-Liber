import Testing
@testable import Domain

// binds: SU-M15-VOICE (FR17.9/FR17.18 source identity and SP-55 lifecycle)
@Suite("SP-55 refinement source state")
struct TranscriptRefinementStateTests {
    @Test func revocationInvalidatesSelectedAndPendingSuggestions() throws {
        var state = TranscriptRefinementState()
        state.edit("No cough")
        state.select(.refined, authorized: true)
        let pendingRequest = state.beginRefinement(authorized: true, authorizationGeneration: 0)
        let request = try #require(pendingRequest)
        let result = TranscriptRevision(original: "No cough", suggested: "No cough.", safety: .accepted)
        let published = state.publish(result, for: request, authorized: true, authorizationGeneration: 0)
        #expect(published)
        let confirmation = state.snapshot(authorized: true, authorizationGeneration: 0)
        #expect(confirmation.selectedText == "No cough.")
        #expect(state.snapshot(authorized: false, authorizationGeneration: 0).selectedText == "No cough")
        #expect(!state.matches(confirmation, authorized: false, authorizationGeneration: 0))

        state.revokeAI()
        #expect(state.version == .native)
        #expect(state.revision == nil)
        #expect(!state.matches(confirmation, authorized: true, authorizationGeneration: 0))
        let publishedAfterRevocation = state.publish(result, for: request, authorized: true, authorizationGeneration: 0)
        #expect(!publishedAfterRevocation)
        #expect(state.nativeText == "No cough")
    }

    @Test func publicationRechecksPermissionWithoutWaitingForAnObserver() throws {
        var state = TranscriptRefinementState()
        state.edit("No cough")
        state.select(.refined, authorized: true)
        let pendingRequest = state.beginRefinement(authorized: true, authorizationGeneration: 0)
        let request = try #require(pendingRequest)
        let published = state.publish(.init(original: "No cough", suggested: "No cough.", safety: .accepted),
                                      for: request, authorized: false, authorizationGeneration: 0)
        #expect(!published)
        #expect(state.revision == nil)
        #expect(state.version == .native)
        #expect(!state.isRefining)
    }

    @Test func revokeAndRegrantBeforeAnObserverRunsCannotReviveASelectedSuggestion() throws {
        var state = TranscriptRefinementState()
        state.edit("No cough")
        state.select(.refined, authorized: true)
        let pendingRequest = state.beginRefinement(authorized: true, authorizationGeneration: 1)
        let request = try #require(pendingRequest)
        let published = state.publish(.init(original: "No cough", suggested: "No cough.", safety: .accepted),
                                      for: request, authorized: true, authorizationGeneration: 1)
        #expect(published)
        let source = state.snapshot(authorized: true, authorizationGeneration: 1)
        #expect(state.snapshot(authorized: true, authorizationGeneration: 3).selectedText == "No cough")
        #expect(!state.matches(source, authorized: true, authorizationGeneration: 3))
        #expect(!state.canCommit(source, authorized: true, authorizationGeneration: 3, preservesOriginal: true))
    }

    @Test func revokeAndRegrantBeforeAnObserverRunsRejectsPendingPublication() throws {
        var state = TranscriptRefinementState()
        state.edit("No cough")
        state.select(.refined, authorized: true)
        let pendingRequest = state.beginRefinement(authorized: true, authorizationGeneration: 1)
        let request = try #require(pendingRequest)
        let published = state.publish(.init(original: "No cough", suggested: "No cough.", safety: .accepted),
                                      for: request, authorized: true, authorizationGeneration: 3)
        #expect(!published)
        #expect(state.revision == nil)
        #expect(state.version == .native)
    }

    @Test func sameTextAfterClearCannotReviveAnOldRequest() throws {
        var state = TranscriptRefinementState()
        state.edit("No cough")
        state.select(.refined, authorized: true)
        let pendingRequest = state.beginRefinement(authorized: true, authorizationGeneration: 0)
        let old = try #require(pendingRequest)
        state.clearAll()
        state.edit("No cough")
        state.select(.refined, authorized: true)
        _ = state.beginRefinement(authorized: true, authorizationGeneration: 0)
        let published = state.publish(.init(original: "No cough", suggested: "No cough.", safety: .accepted),
                                      for: old, authorized: true, authorizationGeneration: 0)
        #expect(!published)
        #expect(state.revision == nil)
    }

    @Test func nativeSelectionAndEditsInvalidateConfirmationSnapshots() throws {
        var state = TranscriptRefinementState()
        state.edit("No cough")
        state.select(.refined, authorized: true)
        let pendingRequest = state.beginRefinement(authorized: true, authorizationGeneration: 0)
        let request = try #require(pendingRequest)
        let published = state.publish(.init(original: "No cough", suggested: "No cough.", safety: .accepted),
                                      for: request, authorized: true, authorizationGeneration: 0)
        #expect(published)
        let source = state.snapshot(authorized: true, authorizationGeneration: 0)
        #expect(source.nativeText == "No cough")
        #expect(source.selectedText == "No cough.")
        state.select(.native, authorized: true)
        #expect(!state.matches(source, authorized: true, authorizationGeneration: 0))
        let native = state.snapshot(authorized: false, authorizationGeneration: 0)
        state.edit("No fever")
        state.edit("No cough")
        #expect(!state.matches(native, authorized: false, authorizationGeneration: 0))
    }

    @Test func changedSuggestionCannotCommitWithoutOriginalPersistence() throws {
        var state = TranscriptRefinementState()
        state.edit("No cough")
        state.select(.refined, authorized: true)
        let pendingRequest = state.beginRefinement(authorized: true, authorizationGeneration: 0)
        let request = try #require(pendingRequest)
        let published = state.publish(.init(original: "No cough", suggested: "No cough.", safety: .accepted),
                                      for: request, authorized: true, authorizationGeneration: 0)
        #expect(published)
        let source = state.snapshot(authorized: true, authorizationGeneration: 0)
        #expect(source.requiresOriginalPersistence)
        #expect(!state.canCommit(source, authorized: true, authorizationGeneration: 0, preservesOriginal: false))
        #expect(state.canCommit(source, authorized: true, authorizationGeneration: 0, preservesOriginal: true))
        #expect(!state.canCommit(source, authorized: false, authorizationGeneration: 0, preservesOriginal: true))
        state.select(.native, authorized: true)
        let native = state.snapshot(authorized: false, authorizationGeneration: 0)
        #expect(state.canCommit(native, authorized: false, authorizationGeneration: 0, preservesOriginal: false))
    }

    @Test func stoppingInferenceLetsNativeConfirmationProceedAndRejectsLateOutput() throws {
        var state = TranscriptRefinementState()
        state.edit("No cough")
        state.select(.refined, authorized: true)
        let pendingRequest = state.beginRefinement(authorized: true, authorizationGeneration: 0)
        let request = try #require(pendingRequest)
        state.cancelRefinement()
        let source = state.snapshot(authorized: true, authorizationGeneration: 0)
        #expect(source.selectedText == "No cough")
        #expect(state.canCommit(source, authorized: true, authorizationGeneration: 0, preservesOriginal: false))
        let published = state.publish(.init(original: "No cough", suggested: "No cough.", safety: .accepted),
                                      for: request, authorized: true, authorizationGeneration: 0)
        #expect(!published)
    }

    @Test func manualEditingDisablesStaleClearLastButNotClearAll() {
        var state = TranscriptRefinementState()
        state.append("weight 60kg")
        state.append("walked")
        state.edit("weight 65kg\nwalked")
        #expect(!state.canClearLast)
        let cleared = state.clearLast()
        #expect(!cleared)
        #expect(state.nativeText == "weight 65kg\nwalked")
        state.clearAll()
        #expect(state.nativeText.isEmpty)
        #expect(state.version == .native)
        #expect(state.revision == nil)
    }

    @Test func clearingAnAppendedRecordingPreservesTheEditedPrefixAndWholeRecordingBoundary() {
        var state = TranscriptRefinementState()
        state.edit("weight 65kg")
        state.append("first line\nsecond line")
        let cleared = state.clearLast()
        #expect(cleared)
        #expect(state.nativeText == "weight 65kg")
        #expect(!state.canClearLast)
    }

    @Test func appendBoundaryPreservesExactUnicodeAndTrailingWhitespace() {
        var state = TranscriptRefinementState()
        let original = "cafe\u{301} \r"
        state.edit(original)
        state.append("new recording")
        let cleared = state.clearLast()
        #expect(cleared)
        #expect(state.nativeText.utf8.elementsEqual(original.utf8))
    }

    @Test func appendingRecognitionDoesNotTrimItsNativeSource() {
        var state = TranscriptRefinementState()
        let original = "  No cough\t\n"
        state.append(original)
        #expect(state.nativeText.utf8.elementsEqual(original.utf8))
        let cleared = state.clearLast()
        #expect(cleared)
        #expect(state.nativeText.isEmpty)
    }

    @Test func anotherPanelWithIdenticalTextCannotReuseASnapshot() {
        var first = TranscriptRefinementState()
        var second = TranscriptRefinementState()
        first.edit("native draft")
        second.edit("native draft")
        let source = first.snapshot(authorized: false, authorizationGeneration: 0)
        #expect(!second.matches(source, authorized: false, authorizationGeneration: 0))
    }

    @Test func revisionWithAnotherOriginalNeverBecomesVisible() throws {
        var state = TranscriptRefinementState()
        state.edit("native")
        state.select(.refined, authorized: true)
        let pendingRequest = state.beginRefinement(authorized: true, authorizationGeneration: 0)
        let request = try #require(pendingRequest)
        let published = state.publish(.init(original: "other", suggested: "other.", safety: .accepted),
                                      for: request, authorized: true, authorizationGeneration: 0)
        #expect(!published)
        #expect(state.snapshot(authorized: true, authorizationGeneration: 0).selectedText == "native")
        #expect(!state.isRefining)
    }

    @Test func failedSaveAndLateSaveCompletionNeverEraseNativeDraft() {
        var state = TranscriptRefinementState()
        state.edit("native draft")
        let source = state.snapshot(authorized: false, authorizationGeneration: 0)
        let clearedAfterFailure = state.finishCommit(source, authorized: false, authorizationGeneration: 0, succeeded: false)
        #expect(!clearedAfterFailure)
        #expect(state.nativeText == "native draft")
        #expect(state.matches(source, authorized: false, authorizationGeneration: 0))
        state.edit("newer native draft")
        let clearedStaleSnapshot = state.finishCommit(source, authorized: false, authorizationGeneration: 0, succeeded: true)
        #expect(!clearedStaleSnapshot)
        #expect(state.nativeText == "newer native draft")
        let current = state.snapshot(authorized: false, authorizationGeneration: 0)
        let clearedCurrentSnapshot = state.finishCommit(current, authorized: false, authorizationGeneration: 0, succeeded: true)
        #expect(clearedCurrentSnapshot)
        #expect(state.nativeText.isEmpty)
    }

    @Test func nativeConfirmationDoesNotDependOnAIAuthorization() {
        var state = TranscriptRefinementState()
        state.edit("native draft")
        let source = state.snapshot(authorized: true, authorizationGeneration: 1)
        state.revokeAI()
        #expect(state.matches(source, authorized: false, authorizationGeneration: 2))
        #expect(state.canCommit(source, authorized: false, authorizationGeneration: 2, preservesOriginal: false))
    }
}
