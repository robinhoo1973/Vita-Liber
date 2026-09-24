#if os(iOS) || os(macOS)
import Foundation
import Testing
import Infrastructure

@Suite("Medical catalog release trust")
struct MedicalCatalogUpdateTests {
    @Test("malformed trust envelopes are rejected before package opening")
    func malformedTrustEnvelopeRejected() {
        let verifier = CryptoKitMedicalCatalogTrustVerifier()
        #expect(throws: MedicalCatalogTrustError.self) {
            try verifier.verify(
                rootJSON: Data("{}".utf8),
                catalogJSON: Data("{}".utf8),
                expectedContentSHA256: String(repeating: "a", count: 64),
                expectedManifestSHA256: String(repeating: "b", count: 64),
                expectedCatalogVersion: 1)
        }
    }
}
#endif
