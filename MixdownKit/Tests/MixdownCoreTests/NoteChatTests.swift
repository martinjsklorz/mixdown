import Foundation
import MixdownCore
import Testing

struct NoteChatTests {
    // MARK: Citations

    @Test func findsCitations() {
        let pieces = ChatCitations.pieces(
            of: "It moves to Friday [2]. Anna writes it [1, 3][Excerpt 4].",
            valid: [1, 2, 3, 4]
        )

        #expect(
            pieces == [
                .text("It moves to Friday "), .citation(2), .text(". Anna writes it "), .citation(1), .citation(3),
                .citation(4), .text("."),
            ]
        )
    }

    @Test func keepsBracketsThatCiteNothingKnown() {
        let pieces = ChatCitations.pieces(of: "See [9] and [x] and [2, 9].", valid: [2])

        #expect(pieces == [.text("See [9] and [x] and "), .citation(2), .text(".")])
    }

    @Test func removesCitations() {
        #expect(ChatCitations.removingCitations(from: "Friday [2]. Anna [1, 3][Excerpt 4].") == "Friday. Anna.")
        #expect(ChatCitations.removingCitations(from: "Anna [9] and Ben [x] [2]\nlater") == "Anna and Ben [x]\nlater")
    }

    @Test func numbersInOrderOfFirstCitation() {
        #expect(ChatCitations.numbers(in: "A [3]. B [1][3]. C [2]", valid: [1, 2, 3]) == [3, 1, 2])
    }

    // MARK: Embeddings

    @Test func embeddingsAreUnitLength() {
        let embedding = TextEmbedding(model: "m", vector: [3, 4])

        #expect(embedding.vector == [0.6, 0.8])
        #expect(abs(embedding.similarity(to: embedding.vector) - 1) < 0.0001)
        #expect(embedding.similarity(to: [1, 0, 0]) == 0)
        #expect(TextEmbedding(model: "m", vector: [0, 0]).vector == [0, 0])
    }

    @Test func embeddingsSurviveCoding() throws {
        let embedding = TextEmbedding(model: "m", vector: [1, 2, 3])

        let decoded = try PropertyListDecoder().decode(
            TextEmbedding.self,
            from: try PropertyListEncoder().encode(embedding)
        )

        #expect(decoded == embedding)
    }
}
