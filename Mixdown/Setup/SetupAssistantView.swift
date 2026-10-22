import MixdownCore
import SwiftUI

/// Walks through setting Mixdown up, a page at a time: the notes folder and the speech model that
/// recording needs, the inputs and their permissions, then calls, notifications and shortcuts.
///
/// Shown over the main window at first launch, until it's finished or put off with **Set Up
/// Later**; Help › Setup Assistant… opens it again. Everything it sets is in Settings too, and
/// Record still asks for whatever is missing.
struct SetupAssistantView: View {
    enum Step: Int, CaseIterable {
        case welcome
        case notesFolder
        case model
        case inputs
        case calls
        case shortcuts
        case done
    }

    @Environment(AppEnvironment.self) private var environment
    @Environment(MainNavigation.self) private var navigation
    @State private var step = Step.welcome

    var body: some View {
        VStack(spacing: 0) {
            page
                .id(step)
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            pageDots
                .padding(.vertical, 12)
            Divider()
            footer
        }
        .frame(width: 580, height: 580)
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome: WelcomePage()
        case .notesFolder: NotesFolderPage()
        case .model: ModelPage()
        case .inputs: InputsPage()
        case .calls: CallsPage()
        case .shortcuts: ShortcutsPage()
        case .done: DonePage()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step != .done {
                Button("Set Up Later", action: finish)
                    .keyboardShortcut(.cancelAction)
                    .help("Close the assistant. Open it again from Help › Setup Assistant….")
            }
            Spacer()
            if step != .welcome {
                Button("Back") { go(to: step.rawValue - 1) }
            }
            Button(continueTitle, action: next)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
        }
        .controlSize(.large)
        .padding(16)
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(Step.allCases, id: \.self) { page in
                Circle()
                    .fill(page == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    // MARK: Moving on

    private var continueTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .model where startsDownload: "Download and Continue"
        case .done: "Start Using Mixdown"
        default: "Continue"
        }
    }

    /// Recording needs a notes folder; the rest can be done later.
    private var canContinue: Bool {
        step != .notesFolder || environment.notesFolder.directory != nil
    }

    /// Whether continuing from the model page starts downloading it, which then carries on in the
    /// background.
    private var startsDownload: Bool {
        !environment.coordinator.isModelDownloaded && environment.coordinator.isIdle
    }

    private func next() {
        if step == .model, startsDownload {
            let coordinator = environment.coordinator
            Task { await coordinator.prepareEngine() }
        }
        if step == .done {
            finish()
        } else {
            go(to: step.rawValue + 1)
        }
    }

    private func go(to rawValue: Int) {
        guard let step = Step(rawValue: rawValue) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { self.step = step }
    }

    /// Closes the assistant for good, leaving Record to show what's still missing.
    private func finish() {
        let settings = AppSettings()
        settings.needsSetup = false
        navigation.destination = .recorder
        navigation.isShowingSetup = false
    }
}
