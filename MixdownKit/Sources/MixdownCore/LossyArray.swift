import Foundation

/// An array decoded element by element, leaving out the elements that can't be decoded, so one
/// odd entry in a stored list loses only itself, not the whole list.
public struct LossyArray<Element: Decodable>: Decodable {
    public var elements: [Element]

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // A failed decode doesn't move on to the next element; this does.
                _ = try container.decode(Skipped.self)
            }
        }
        self.elements = elements
    }

    /// Decodes from anything, to step over an element.
    private struct Skipped: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

extension KeyedDecodingContainer {
    /// The elements at `key` that can be decoded; empty if there's no array there.
    func decodeLossyArray<Element: Decodable>(_ type: [Element].Type, forKey key: Key) -> [Element] {
        (try? decodeIfPresent(LossyArray<Element>.self, forKey: key))?.elements ?? []
    }
}
