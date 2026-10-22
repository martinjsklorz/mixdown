import AppKit
import MixdownCore
import SwiftUI

/// The summary templates: a list of them, and the selected one to edit. Built-ins can be edited
/// and restored; the user's own can be added, duplicated and deleted.
struct TemplatesSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selectedID: String? = SummaryTemplate.general.id
    @State private var templateToDelete: SummaryTemplate?

    var body: some View {
        // The other tabs are one full-width Form, whose scroll view runs under the whole toolbar
        // and backs it. Here only the editor's Form would, leaving the toolbar items over the list
        // without their hover highlight, so a fixed full-width scroll view backs the toolbar instead.
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scrollDisabled(false)
            }
            .scrollDisabled(true)
            .scrollEdgeEffectStyle(.hard, for: .top)
        }
    }

    private var content: some View {
        HStack(spacing: 0) {
            templateList
                .frame(width: 190)
                .padding([.leading, .vertical], 20)
            if let template = selectedTemplate {
                editor(for: template)
                    // A fresh editor per template, so the text views don't carry over.
                    .id(template.id)
            } else {
                ContentUnavailableView("No Template Selected", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .confirmationDialog(
            "Delete “\(templateToDelete?.displayName ?? "")”?",
            isPresented: Binding(get: { templateToDelete != nil }, set: { if !$0 { templateToDelete = nil } }),
            presenting: templateToDelete
        ) { template in
            Button("Delete", role: .destructive) { delete(template) }
        } message: { _ in
            Text("Notes already summarized with it keep their summaries. Recordings set to use it get General instead.")
        }
    }

    private var selectedTemplate: SummaryTemplate? {
        environment.summaryTemplates.first { $0.id == selectedID }
    }

    // MARK: List

    private var templateList: some View {
        let templates = environment.summaryTemplates
        let custom = templates.filter { !$0.isBuiltIn }

        return VStack(spacing: 0) {
            List(selection: $selectedID) {
                Section("Built-in") {
                    ForEach(templates.filter(\.isBuiltIn)) { row(for: $0) }
                }
                if !custom.isEmpty {
                    Section("Yours") {
                        ForEach(custom) { row(for: $0) }
                    }
                }
            }
            .listStyle(.plain)
            .onDeleteCommand {
                if let selectedTemplate, !selectedTemplate.isBuiltIn { templateToDelete = selectedTemplate }
            }

            Divider()
            HStack(spacing: 0) {
                Button("Add Template", systemImage: "plus") { add(copying: nil) }
                    .help("Add a template")
                Button("Delete Template", systemImage: "minus") { templateToDelete = selectedTemplate }
                    .help("Delete the selected template")
                    .disabled(selectedTemplate?.isBuiltIn ?? true)
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .frame(height: 24)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private func row(for template: SummaryTemplate) -> some View {
        HStack {
            Text(template.displayName)
                .lineLimit(1)
            Spacer()
            if template.isEdited {
                Text("Edited")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(template.id)
        .contextMenu {
            Button("Duplicate") { add(copying: template) }
            if !template.isBuiltIn {
                Button("Delete…") { templateToDelete = template }
            }
        }
    }

    // MARK: Editor

    private func editor(for template: SummaryTemplate) -> some View {
        Form {
            Section {
                TextField("Name", text: binding(\.name, of: template), prompt: Text("Sprint Review"))
                Picker("Sections", selection: binding(\.layout, of: template)) {
                    ForEach(SummaryTemplate.Layout.allCases) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Action items are checkboxes. With TL;DR, every section is shown, with _None._ if it's empty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: binding(\.instructions, of: template))
                    .font(.body)
                    .frame(minHeight: 120)
                    .accessibilityLabel("Instructions")
            } header: {
                Text("Instructions")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text(
                        "What kind of recording this is and what to look out for, e.g. \"The recording is a "
                            + "sprint review. Look out for what was shown and the feedback on it.\" Leave it "
                            + "empty for a summary of anything."
                    )
                    Spacer()
                    Text("\(template.instructions.count)/\(SummaryTemplate.maximumInstructionsLength)")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Duplicate") { add(copying: template) }
                    Spacer()
                    if template.isBuiltIn {
                        Button("Restore Default") { environment.restoreSummaryTemplate(id: template.id) }
                            .disabled(!template.isEdited)
                    } else {
                        Button("Delete…", role: .destructive) { templateToDelete = template }
                    }
                }
            } footer: {
                Text("Changes are used from the next summary on, including the recording under way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// A field of the template with `template`'s id, as it is in the environment, saved as it's
    /// edited.
    private func binding<Value>(
        _ keyPath: WritableKeyPath<SummaryTemplate, Value>,
        of template: SummaryTemplate
    ) -> Binding<Value> {
        let current = { environment.summaryTemplates.first { $0.id == template.id } ?? template }
        return Binding(
            get: { current()[keyPath: keyPath] },
            set: { value in
                var edited = current()
                edited[keyPath: keyPath] = value
                environment.updateSummaryTemplate(edited)
            }
        )
    }

    // MARK: Actions

    private func add(copying original: SummaryTemplate?) {
        selectedID = environment.addSummaryTemplate(copying: original).id
    }

    private func delete(_ template: SummaryTemplate) {
        environment.deleteSummaryTemplate(id: template.id)
        if selectedID == template.id { selectedID = SummaryTemplate.general.id }
    }
}
