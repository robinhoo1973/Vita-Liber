import Testing
import Foundation
@testable import Domain
@testable import Protocols
@testable import Infrastructure

@Suite("Core ML matcher contract")
struct CoreMLElementMatcherTests {
    @Test("input template substitutes kind and line")
    func inputTemplate() {
        #expect(CoreMLElementMatcher.inputText(line: "科室：骨科", kind: "encounter",
                                               template: "{kind}\t{line}") == "encounter\t科室：骨科")
        #expect(CoreMLElementMatcher.inputText(line: "科室：骨科", kind: "encounter",
                                               template: nil) == "科室：骨科")
    }

    @Test("catalog decodes identity, feature and integrity fields")
    func catalogDecodes() throws {
        let json = """
        {"formatVersion":1,"modelFile":"m.mlmodelc","version":"1.0.0",
         "inputName":"features","labelOutputName":"label","probabilityOutputName":"labelProbs",
         "keys":["hospital"],"minimumConfidence":0.5,
         "modelID":"field-linerole-abc","featureVersion":"char-ngram-fnv1a-v1",
         "featureDimension":4096,"sha256":"aa","bytes":3,"hashFile":""}
        """
        let catalog = try JSONDecoder().decode(CoreMLElementMatcher.Catalog.self,
                                               from: Data(json.utf8))
        #expect(catalog.modelID == "field-linerole-abc")
        #expect(catalog.featureDimension == 4096)
        #expect(catalog.featureVersion == CharNGramVectorizer.version)
        #expect(catalog.keys == ["hospital"])
    }
}
