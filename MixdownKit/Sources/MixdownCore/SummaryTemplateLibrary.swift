import Foundation

/// Every summary template on offer, and which of them recordings use: the built-ins, edited or
/// not, then the user's own.
///
/// The templates for recordings are kept by id, so they follow edits and fall back to General
/// once their template is deleted.
public struct SummaryTemplateLibrary: Sendable, Hashable {
    /// The built-ins first, in their own order, then the user's templates in theirs.
    public private(set) var templates: [SummaryTemplate]
    /// The id of the template for recordings started by hand.
    public private(set) var recordingTemplateID: String
    /// The id of the template for recordings started for a call, from the call notification or
    /// automatically.
    public private(set) var callTemplateID: String

    /// `stored` as a library, as `SummaryTemplate.list(from:)` would list it. A missing id means
    /// General.
    public init(stored: [SummaryTemplate] = [], recordingTemplateID: String? = nil, callTemplateID: String? = nil) {
        templates = SummaryTemplate.list(from: stored)
        self.recordingTemplateID = recordingTemplateID ?? SummaryTemplate.general.id
        self.callTemplateID = callTemplateID ?? SummaryTemplate.general.id
    }

    /// The templates to store: only what differs from the built-ins as they came.
    public var changedTemplates: [SummaryTemplate] {
        templates.filter { !$0.isBuiltIn || $0.isEdited }
    }

    /// The template for recordings started by hand.
    public var recordingTemplate: SummaryTemplate {
        get { template(id: recordingTemplateID) }
        set { recordingTemplateID = newValue.id }
    }

    /// The template for recordings started for a call.
    public var callTemplate: SummaryTemplate {
        get { template(id: callTemplateID) }
        set { callTemplateID = newValue.id }
    }

    /// The template with `id`, or General if there's none, e.g. because the user deleted it.
    public func template(id: String?) -> SummaryTemplate {
        templates.first { $0.id == id } ?? templates.first { $0.id == SummaryTemplate.general.id } ?? .general
    }

    /// Saves the user's changes to a template, with at most
    /// `SummaryTemplate.maximumInstructionsLength` characters of instructions. Ignored for a
    /// template not in the library.
    public mutating func update(_ template: SummaryTemplate) {
        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return }
        var template = template
        template.instructions = String(template.instructions.prefix(SummaryTemplate.maximumInstructionsLength))
        templates[index] = template
    }

    /// Adds a template of the user's, a copy of `original` or else a blank one, and returns it.
    @discardableResult
    public mutating func add(copying original: SummaryTemplate? = nil) -> SummaryTemplate {
        let template =
            original.map { SummaryTemplate.copy(of: $0, in: templates) } ?? SummaryTemplate.new(in: templates)
        templates.append(template)
        return template
    }

    /// Deletes a template of the user's. Recordings set to use it get General instead. Built-ins
    /// can't be deleted.
    public mutating func delete(id: String) {
        guard SummaryTemplate.builtIn(id: id) == nil else { return }
        templates.removeAll { $0.id == id }
        if recordingTemplateID == id { recordingTemplateID = SummaryTemplate.general.id }
        if callTemplateID == id { callTemplateID = SummaryTemplate.general.id }
    }

    /// Puts a built-in template back the way it came.
    public mutating func restore(id: String) {
        guard let original = SummaryTemplate.builtIn(id: id) else { return }
        update(original)
    }
}
