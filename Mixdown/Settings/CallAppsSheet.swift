import AppKit
import MixdownCore
import SwiftUI
import UniformTypeIdentifiers

/// Which apps count as calls: a switch for each known call app and browser, and apps the user
/// added, which can be removed again.
struct CallAppsSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    /// Icons of the apps, by `CallApp.id`: the installed app's own, or else the one bundled for a
    /// known app.
    @State private var icons: [String: NSImage] = [:]
    @State private var addError: String?

    private var selection: CallAppSelection { environment.preferences.callApps }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(CallApp.known.filter { !$0.isBrowser }) { app in
                        toggle(for: app)
                    }
                } header: {
                    Text("Call Apps")
                }

                Section {
                    ForEach(CallApp.known.filter(\.isBrowser)) { app in
                        toggle(for: app)
                    }
                } header: {
                    Text("Browsers")
                } footer: {
                    Caption(
                        "A browser counts as soon as any website uses the microphone, such as Google Meet. "
                            + "Safari's switch covers other apps showing web pages too."
                    )
                }

                Section {
                    ForEach(selection.added) { app in
                        HStack {
                            label(for: app)
                            Spacer()
                            Button("Remove") { set(app, included: false) }
                        }
                    }
                    Button("Add App…", action: addApp)
                } header: {
                    Text("Other Apps")
                } footer: {
                    Caption("Add any other app you hold calls in. Its helper apps count too.")
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440, height: 600)
        .task { loadIcons() }
        .alert(
            "Can't Add This App",
            isPresented: Binding(get: { addError != nil }, set: { if !$0 { addError = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(addError ?? "")
        }
    }

    private func toggle(for app: CallApp) -> some View {
        Toggle(
            isOn: Binding(
                get: { selection.includes(app) },
                set: { set(app, included: $0) }
            )
        ) {
            label(for: app)
        }
    }

    private func label(for app: CallApp) -> some View {
        Label {
            Text(app.name)
        } icon: {
            if let icon = icons[app.id] {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            } else {
                // Not installed, and added by the user or without a bundled icon.
                Image(systemName: app.isBrowser ? "globe" : "phone")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
        }
    }

    private func set(_ app: CallApp, included: Bool) {
        environment.preferences.callApps.set(app, included: included)
    }

    private func loadIcons() {
        for app in CallApp.known + selection.added {
            if let url = app.bundleIDs.lazy.compactMap({
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            }).first {
                icons[app.id] = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                icons[app.id] = Self.bundledIcon(for: app)
            }
        }
    }

    /// The icon in the asset catalog's `CallApps` folder for a known app that isn't installed,
    /// named after its `id` with dashes for dots, as `NSImage(named:)` takes a dot for an extension.
    private static func bundledIcon(for app: CallApp) -> NSImage? {
        NSImage(named: "CallApps/" + app.id.replacingOccurrences(of: ".", with: "-"))
    }

    /// Asks for an app and adds it, or turns it on if it's known already.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose an app you hold calls in."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
            addError = "\(url.deletingPathExtension().lastPathComponent) has no bundle identifier."
            return
        }
        let name =
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let app = environment.preferences.callApps.add(name: name, bundleID: bundleID)
        icons[app.id] = icons[app.id] ?? NSWorkspace.shared.icon(forFile: url.path)
    }
}
