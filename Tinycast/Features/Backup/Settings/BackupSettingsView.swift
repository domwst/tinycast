import AppKit
import SwiftUI

struct BackupSettingsView: View {
    @Environment(AppCore.self) private var core
    private var runningApps: RunningAppsMonitor { core.runningApps }
    @State private var raycastFile: URL?
    @State private var passphrase = ""
    @State private var importing = false
    @State private var status: Status?
    @State private var selection: RaycastImportOptions = .all
    @State private var isRaycastExport = false
    @State private var exportSelection = BackupCategory.all
    @State private var importSelection: Set<BackupCategory> = []
    @State private var exporting = false
    @State private var exportPassphrase = ""
    @State private var exportConfirmation = ""
    @State private var exportStatus: Status?
    @State private var importingBackup = false
    @State private var importStatus: Status?
    @State private var backupFile: URL?
    @State private var backupIsEncrypted = false
    @State private var backupPassphrase = ""
    @State private var openingBackup = false
    /// Cleared by leaving the pane or choosing again, so a late decrypt discards its own tree.
    @State private var openRequest: UUID?
    @State private var openedManifest: BackupManifest?
    /// Kept for Import, which unpacks the file again: the preview extracts only its manifest.
    @State private var openedPassphrase: String?

    private enum Status {
        case success(String)
        case failure(String)
    }

    private var raycastRunning: Bool {
        runningApps.runningBundleIDs.contains(where: BackupActions.isRaycastBundleID)
    }

    /// Turning it on may ask first, so the switch follows the setting rather than the click.
    private var settingsFileSync: Binding<Bool> {
        Binding(
            get: { core.settings.settingsFileEnabled },
            set: { enabled in Task { await BackupActions.setSettingsFileEnabled(enabled, core: core) } })
    }

    private var raycastFileSubtitle: String {
        guard let name = raycastFile?.lastPathComponent else {
            return String(localized: "A .rayconfig file from Raycast 2.0 or later.")
        }
        return isRaycastExport
            ? String(localized: "\(name) — Raycast export")
            : String(localized: "\(name) — not a Raycast export")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if exporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Export…") { runExport() }.disabled(!canExport)
                    }
                } label: {
                    SettingsRowTitle(.backupExport, "Export Backup")
                    Text("The ticked items, as one encrypted .tinycast file.")
                }
                LabeledContent {
                    passphraseField(
                        $exportPassphrase,
                        prompt: Text("At least \(BackupArchive.minimumPassphraseLength) characters"),
                        onSubmit: runExport)
                } label: {
                    Text("Passphrase")
                    Text("Needed to import the backup. It can't be recovered if you forget it.")
                }
                LabeledContent {
                    passphraseField($exportConfirmation, prompt: Text("Repeat it"), onSubmit: runExport)
                } label: {
                    Text("Confirm Passphrase")
                }
                if exportPassphrasesDiffer {
                    Label("The passphrases don't match.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                BackupCategorySelection(selection: $exportSelection)
                if let exportStatus { statusRow(exportStatus) }
            } header: {
                SettingsSectionHeader(.backupExport)
            }

            Section {
                LabeledContent {
                    Button("Choose…") { chooseBackupFile() }
                } label: {
                    SettingsRowTitle(.backupImport, "Backup File")
                    Text(backupFileSubtitle)
                }
                if backupIsEncrypted, openedManifest == nil {
                    LabeledContent {
                        passphraseField(
                            $backupPassphrase, prompt: Text("Backup passphrase"),
                            onSubmit: openEncryptedBackup)
                    } label: {
                        Text("Passphrase")
                    }
                    LabeledContent {
                        if openingBackup {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Open") { openEncryptedBackup() }
                                .disabled(backupPassphrase.isEmpty)
                        }
                    } label: {
                        Text("Open Backup")
                    }
                }
                if let manifest = openedManifest {
                    BackupCategorySelection(
                        selection: $importSelection, available: available(in: manifest))
                    LabeledContent {
                        if importingBackup {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Import") { runBackupImport() }
                                .disabled(importSelection.isEmpty)
                        }
                    } label: {
                        Text("Import")
                    }
                }
                if let importStatus { statusRow(importStatus) }
            } header: {
                SettingsSectionHeader(.backupImport)
            }

            Section {
                LabeledContent {
                    Button("Choose…") { chooseRaycastFile() }
                } label: {
                    SettingsRowTitle(.backupImportFromRaycast, "Raycast Export")
                    Text(raycastFileSubtitle)
                }
                LabeledContent {
                    passphraseField(
                        $passphrase, prompt: Text("Export password"), onSubmit: runRaycastImport)
                } label: {
                    Text("Passphrase")
                }
                RaycastImportSelection(selection: $selection)
                conflictNotice
                LabeledContent {
                    if importing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Import") { runRaycastImport() }
                            .disabled(!isRaycastExport || passphrase.isEmpty || selection.isEmpty)
                    }
                } label: {
                    Text("Import")
                }
                if let status { statusRow(status) }
            } header: {
                SettingsSectionHeader(.backupImportFromRaycast)
            }

            Section {
                Toggle(isOn: settingsFileSync) {
                    SettingsRowTitle(.backupSettingsFile, "Sync settings file")
                    Text(BackupActions.settingsFilePath)
                }
                if core.settings.settingsFileEnabled {
                    LabeledContent {
                        Button("Show in Finder", action: BackupActions.revealSettingsFile)
                    } label: {
                        Text("Settings changed here are written to the file, and edits to it apply here.")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                SettingsSectionHeader(.backupSettingsFile)
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.backup)
        .onDisappear { if !importingBackup { discardStagedBackup() } }
    }

    @ViewBuilder
    private var conflictNotice: some View {
        if raycastRunning {
            LabeledContent {
                Button("Quit Raycast") { BackupActions.quitRaycast() }
            } label: {
                Label(
                    "Raycast is running — quit it to avoid hotkey conflicts.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
        } else {
            Label(
                "Unset matching Raycast shortcuts to avoid conflicts.",
                systemImage: "info.circle"
            )
            .foregroundStyle(.secondary)
        }
    }

    private func passphraseField(
        _ text: Binding<String>, prompt: Text, onSubmit: @escaping () -> Void
    ) -> some View {
        RevealableSecureField(title: String(localized: "Passphrase"), text: text, prompt: prompt)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            // LabeledContent right-aligns its value text, caret and all; a field reads left.
            .multilineTextAlignment(.leading)
            .frame(width: 160)
            .onSubmit(onSubmit)
    }

    private var exportPassphrasesDiffer: Bool {
        !exportConfirmation.isEmpty && exportPassphrase != exportConfirmation
    }

    private var canExport: Bool {
        !exportSelection.isEmpty && exportPassphrase == exportConfirmation
            && exportPassphrase.count >= BackupArchive.minimumPassphraseLength
    }

    @ViewBuilder
    private func statusRow(_ status: Status) -> some View {
        switch status {
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var backupFileSubtitle: String {
        guard let name = backupFile?.lastPathComponent else {
            return String(localized: "A .tinycast file exported from Tinycast.")
        }
        if openedManifest != nil { return name }
        return backupIsEncrypted
            ? String(localized: "\(name) — encrypted")
            : String(localized: "\(name) — couldn't be read")
    }

    private func available(in manifest: BackupManifest) -> [BackupCategory: Int] {
        Dictionary(
            uniqueKeysWithValues: BackupCategory.ordered(manifest.categories).map {
                ($0, manifest.count($0))
            })
    }

    private func runExport() {
        guard !exporting, canExport else { return }
        exporting = true
        exportStatus = nil
        let categories = exportSelection
        let passphrase = exportPassphrase
        Task {
            defer { exporting = false }
            do {
                let result = try await BackupActions.exportBackup(
                    core: core, categories: categories, passphrase: passphrase)
                exportStatus = .success(BackupActions.exportText(result))
                exportPassphrase = ""
                exportConfirmation = ""
            } catch is CancellationError {
                // The user closed the save panel; nothing to report.
            } catch {
                exportStatus = .failure(error.localizedDescription)
            }
        }
    }

    private func chooseBackupFile() {
        guard let url = BackupActions.chooseBackupFile() else { return }
        discardStagedBackup()
        backupFile = url
        backupPassphrase = ""
        importStatus = nil
        backupIsEncrypted = BackupActions.isEncryptedBackup(url)
        if !backupIsEncrypted { openBackup(url, passphrase: nil) }
    }

    private func openEncryptedBackup() {
        guard let url = backupFile, backupIsEncrypted, !backupPassphrase.isEmpty, !openingBackup
        else { return }
        openBackup(url, passphrase: backupPassphrase)
    }

    private func openBackup(_ url: URL, passphrase: String?) {
        let request = UUID()
        openRequest = request
        openingBackup = true
        importStatus = nil
        Task {
            defer { if openRequest == request { openingBackup = false } }
            do {
                let manifest = try await BackupActions.openBackup(at: url, passphrase: passphrase)
                guard openRequest == request else { return }
                openedPassphrase = passphrase
                openedManifest = manifest
                importSelection = manifest.categories
                backupPassphrase = ""
            } catch {
                if openRequest == request { importStatus = .failure(error.localizedDescription) }
            }
        }
    }

    private func runBackupImport() {
        guard let file = backupFile, openedManifest != nil, !importingBackup, !importSelection.isEmpty
        else { return }
        importingBackup = true
        let categories = importSelection
        let passphrase = openedPassphrase
        Task {
            defer { importingBackup = false }
            do {
                let summary = try await BackupActions.applyBackup(
                    categories, file: file, passphrase: passphrase, to: core)
                discardStagedBackup()
                backupFile = nil
                backupIsEncrypted = false
                if let summary { importStatus = .success(BackupActions.summaryText(summary)) }
            } catch {
                importStatus = .failure(error.localizedDescription)
            }
        }
    }

    /// Leaving the pane forgets the opened file and its passphrase; nothing of it is on disk.
    private func discardStagedBackup() {
        openRequest = nil
        openingBackup = false
        openedPassphrase = nil
        openedManifest = nil
    }

    private func chooseRaycastFile() {
        guard let url = BackupActions.pickRaycastFile() else { return }
        raycastFile = url
        isRaycastExport = BackupActions.isRaycastExport(url)
        status = nil
    }

    private func runRaycastImport() {
        guard let file = raycastFile, isRaycastExport, !passphrase.isEmpty, !selection.isEmpty,
            !importing
        else { return }
        importing = true
        status = nil
        Task {
            defer { importing = false }
            do {
                let outcome = try await BackupActions.importRaycast(
                    core: core, file: file, passphrase: passphrase, options: selection)
                status = .success(BackupActions.raycastText(outcome))
                passphrase = ""
            } catch {
                status = .failure(error.localizedDescription)
            }
        }
    }
}
