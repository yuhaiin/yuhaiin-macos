import SwiftUI
import UniformTypeIdentifiers

private extension View {
    @ViewBuilder
    func yuhaiinGlass(cornerRadius: CGFloat = 18) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                }
        }
    }

    @ViewBuilder
    func yuhaiinActionButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            // Keep the control layer neutral. `.glassProminent` inherits the
            // system accent color and becomes a saturated blue block in this
            // app's light and dark appearances.
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

private struct MenuBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(
                configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
    }
}

struct StatusLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: model.state.symbol)
                .symbolRenderingMode(.hierarchical)
            if model.showSpeed && model.isRunning {
                Text("↓ \(model.formattedDownloadRate) ↑ \(model.formattedUploadRate)")
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("status.accessibility"))
        .accessibilityValue(model.state.title)
    }
}

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: model.state.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(model.isRunning ? .green : .secondary)
                    .frame(width: 34, height: 34)
                    .background(.primary.opacity(0.08), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.state.title)
                        .font(.headline)
                    Text(model.isRunning ? L("dashboard.apiConnected") : L("dashboard.apiWaiting"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            if model.isRunning {
                HStack(spacing: 8) {
                    MenuMetric(symbol: "arrow.down", value: model.formattedDownloadRate, tint: .blue)
                    MenuMetric(symbol: "arrow.up", value: model.formattedUploadRate, tint: .mint)
                }
            }

            Divider()

            Button(model.isRunning ? L("menu.stopYuhaiin") : L("menu.startYuhaiin")) {
                model.isRunning ? model.stop() : model.start()
            }
            .buttonStyle(MenuBarButtonStyle())
            .disabled(model.isBusy)

            Button(L("common.openControlPage")) {
                model.openControlPage()
            }
            .buttonStyle(MenuBarButtonStyle())
            .disabled(model.isBusy)

            Button(L("menu.checkAppUpdates")) {
                updater.checkForUpdates()
            }
            .buttonStyle(MenuBarButtonStyle())
            .disabled(!updater.canCheckForUpdates)

            Button(L("menu.checkYuhaiinUpdates")) {
                model.checkYuhaiinUpdate()
            }
            .buttonStyle(MenuBarButtonStyle())
            .disabled(!model.isRunning || model.updateStatusIsRunning)

            Button(L("menu.openMainWindow")) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(MenuBarButtonStyle())

            Divider()

            Button(L("menu.settings")) {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(MenuBarButtonStyle())

            Button(L("menu.quit")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(MenuBarButtonStyle())
        }
        .padding(14)
        .frame(width: 310)
    }
}

private struct MenuMetric: View {
    let symbol: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(value)
                .monospacedDigit()
        }
        .font(.system(.caption, design: .rounded).weight(.medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.06), in: Capsule())
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Yuhaiin")
                            .font(.largeTitle.bold())
                        Text(L("dashboard.subtitle"))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: model.state.symbol)
                            .font(.headline.weight(.medium))
                            .foregroundStyle(model.isRunning ? .green : .secondary)
                        Text(model.state.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .yuhaiinGlass(cornerRadius: 14)
                }

                HStack(spacing: 12) {
                    MetricCard(title: L("metrics.download"), value: model.formattedDownloadRate, symbol: "arrow.down")
                    MetricCard(title: L("metrics.upload"), value: model.formattedUploadRate, symbol: "arrow.up")
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: model.state.symbol)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(model.isRunning ? .green : .secondary)
                            .frame(width: 36, height: 36)
                            .background(.primary.opacity(0.07), in: Circle())

                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.state.title)
                                .font(.headline)
                            Text(model.apiAvailable ? L("dashboard.apiConnected") : L("dashboard.apiWaiting"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    Divider()

                    HStack(spacing: 10) {
                        Button(model.isRunning ? L("common.stop") : L("common.start")) {
                            model.isRunning ? model.stop() : model.start()
                        }
                        .yuhaiinActionButtonStyle(prominent: true)
                        .disabled(model.isBusy)

                        Button(L("common.openControlPage")) {
                            model.openControlPage()
                        }
                        .yuhaiinActionButtonStyle()
                        .disabled(model.isBusy)
                    }
                }
                .padding(20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                }

                if !model.lastError.isEmpty {
                    Label(model.lastError, systemImage: "exclamationmark.triangle.fill")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.orange)
                        .font(.callout)
                }

                HStack {
                    Text(L("dashboard.yuhaiinVersion", model.yuhaiinVersion))
                    Spacer()
                    Text(L("dashboard.localhostAPI", model.apiAvailable ? L("common.available") : L("common.unavailable")))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Label(
                        updater.isConfigured ? L("dashboard.appUpdatesConfigured") : L("dashboard.appUpdatesNotConfigured"),
                        systemImage: updater.isConfigured ? "arrow.down.circle" : "questionmark.circle"
                    )
                    Spacer()
                    Button(L("common.checkForUpdates")) {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                RadialGradient(
                    colors: [
                        (model.isRunning ? Color.green : Color.accentColor).opacity(0.12),
                        .clear
                    ],
                    center: .topTrailing,
                    startRadius: 20,
                    endRadius: 440
                )
                .ignoresSafeArea()
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.14), in: Circle())
                Text(title)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
        }
    }

    private var tint: Color {
        symbol == "arrow.up" ? .mint : .blue
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case service
    case statusBar
    case controlPage
    case runtime
    case authentication
    case appUpdates
    case yuhaiinUpdates
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .service: return L("settings.service")
        case .statusBar: return L("settings.statusBar")
        case .controlPage: return L("settings.controlPage")
        case .runtime: return L("settings.yuhaiinRuntime")
        case .authentication: return L("settings.apiAuthentication")
        case .appUpdates: return L("settings.appUpdates")
        case .yuhaiinUpdates: return L("settings.yuhaiinUpdates")
        case .diagnostics: return L("settings.diagnostics")
        }
    }

    var symbol: String {
        switch self {
        case .service: return "gearshape.2"
        case .statusBar: return "menubar.arrow.up.rectangle"
        case .controlPage: return "safari"
        case .runtime: return "terminal"
        case .authentication: return "key.fill"
        case .appUpdates: return "arrow.down.circle"
        case .yuhaiinUpdates: return "arrow.triangle.2.circlepath"
        case .diagnostics: return "stethoscope"
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: symbol)
                .font(.headline)

            Divider()

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater
    @State private var selection: SettingsSection = .service
    @State private var showMigrationConfirmation = false
    @State private var showUninstallConfirmation = false
    @State private var showBinaryImporter = false

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
            .navigationTitle("Yuhaiin")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(selection.title)
                            .font(.system(.title2, design: .rounded).weight(.bold))
                        Spacer()
                        Image(systemName: selection.symbol)
                            .foregroundStyle(.secondary)
                    }

                    settingsContent
                }
                .padding(28)
            }
            .background {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    RadialGradient(
                        colors: [Color.accentColor.opacity(0.1), .clear],
                        center: .topTrailing,
                        startRadius: 20,
                        endRadius: 460
                    )
                    .ignoresSafeArea()
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 860, minHeight: 620)
        .fileImporter(
            isPresented: $showBinaryImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            model.handleBinaryImport(result)
        }
        .alert(L("migration.title"), isPresented: $showMigrationConfirmation) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("common.migrate"), role: .destructive) {
                model.adoptLegacyService()
            }
        } message: {
            Text(L("migration.message"))
        }
        .alert(L("uninstall.title"), isPresented: $showUninstallConfirmation) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("common.uninstall"), role: .destructive) {
                model.uninstallSupervisor()
            }
        } message: {
            Text(L("uninstall.message"))
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch selection {
        case .service:
            SettingsCard(selection.title, symbol: selection.symbol) {
                HStack {
                    Label(L("settings.supervisor"), systemImage: "lock.shield")
                    Spacer()
                    Text(model.supervisorAuthorized ? L("common.authorized") : L("common.notAuthorized"))
                        .foregroundStyle(model.supervisorAuthorized ? .green : .orange)
                }
                if !model.supervisorAuthorized {
                    HStack {
                        Button(L("settings.installSupervisor")) { model.installSupervisor() }
                            .yuhaiinActionButtonStyle()
                        Button(L("settings.openLoginItems")) { model.openSystemLoginItems() }
                            .yuhaiinActionButtonStyle()
                    }
                } else {
                    Button(L("settings.uninstallSupervisor")) { showUninstallConfirmation = true }
                        .foregroundStyle(.red)
                        .yuhaiinActionButtonStyle()
                }
                Toggle(L("settings.launchAtLogin"), isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Toggle(L("settings.autoStartYuhaiin"), isOn: $model.autoStartYuhaiin)
                Text(L("settings.exitBehavior"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .statusBar:
            SettingsCard(selection.title, symbol: selection.symbol) {
                Toggle(L("settings.showSpeed"), isOn: $model.showSpeed)
            }

        case .controlPage:
            SettingsCard(selection.title, symbol: selection.symbol) {
                HStack {
                    Text(L("settings.port"))
                    Spacer()
                    TextField("50051", text: $model.apiPortText)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .textFieldStyle(.roundedBorder)
                    Button(L("common.apply")) { model.applyAPIPort() }
                        .yuhaiinActionButtonStyle(prominent: true)
                }
                HStack {
                    Text(L("settings.address"))
                    Spacer()
                    Text(model.apiBaseAddress)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Button(L("common.openControlPage")) { model.openControlPage() }
                    .yuhaiinActionButtonStyle()
                Text(model.apiAuthenticationEnabled
                     ? L("settings.localhostAuthEnabled")
                     : L("settings.localhostAuthDisabled"))
                    .font(.caption)
                    .foregroundStyle(model.apiAuthenticationEnabled ? Color.secondary : Color.orange)
            }

        case .runtime:
            SettingsCard(selection.title, symbol: selection.symbol) {
                TextField(L("settings.customBinaryPath"), text: $model.customBinaryPathText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(L("settings.applyBinaryPath")) { model.applyCustomBinaryPath() }
                        .yuhaiinActionButtonStyle(prominent: true)
                    Button(L("settings.useBundledBinary")) { model.useBundledBinary() }
                        .yuhaiinActionButtonStyle()
                }
                HStack {
                    Button(L("settings.uploadBinary")) { showBinaryImporter = true }
                        .yuhaiinActionButtonStyle()
                        .disabled(model.isBusy)
                    if model.binaryUploadInProgress {
                        ProgressView().controlSize(.small)
                    }
                }
                if model.uploadedBinaryInstalled {
                    Label(L("settings.uploadedBinaryActive"), systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
                Text(L("settings.binaryPathNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L("settings.binaryUploadNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .authentication:
            SettingsCard(selection.title, symbol: selection.symbol) {
                Toggle(L("settings.enableBasicAuth"), isOn: $model.apiAuthenticationEnabled)
                if model.apiAuthenticationEnabled {
                    TextField(L("settings.username"), text: $model.apiUsernameText)
                    SecureField(L("settings.password"), text: $model.apiPasswordText)
                }
                Button(L("settings.applyAuth")) { model.applyAPIAuthentication() }
                    .yuhaiinActionButtonStyle(prominent: true)
                Text(L("settings.authApplyNote"))
                    .font(.caption)
                Text(model.apiAuthenticationEnabled
                     ? L("settings.authEnabledNote")
                     : L("settings.authDisabledNote"))
                    .font(.caption)
                    .foregroundStyle(model.apiAuthenticationEnabled ? Color.secondary : Color.orange)
            }

        case .appUpdates:
            SettingsCard(selection.title, symbol: selection.symbol) {
                HStack {
                    Label(L("settings.sparkleFeed"), systemImage: "arrow.down.circle")
                    Spacer()
                    Text(updater.isConfigured ? L("common.configured") : L("common.notConfigured"))
                        .foregroundStyle(updater.isConfigured ? .green : .secondary)
                }
                Button(L("settings.checkAppUpdates")) { updater.checkForUpdates() }
                    .yuhaiinActionButtonStyle(prominent: true)
                    .disabled(!updater.canCheckForUpdates)
                if !updater.isConfigured {
                    Text(L("settings.sparkleNotConfigured"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .yuhaiinUpdates:
            SettingsCard(selection.title, symbol: selection.symbol) {
                HStack {
                    Text(L("settings.currentVersion"))
                    Spacer()
                    Text(model.yuhaiinVersion)
                        .font(.system(.caption, design: .monospaced))
                }
                Button(L("settings.checkYuhaiinUpdates")) { model.checkYuhaiinUpdate() }
                    .yuhaiinActionButtonStyle(prominent: true)
                    .disabled(!model.isRunning || model.updateStatusIsRunning)
                if let update = model.yuhaiinUpdate {
                    if update.updateAvailable {
                        Text(L("settings.updateAvailable", update.targetVersion))
                            .foregroundStyle(.orange)
                        Button(L("settings.installYuhaiinUpdate")) { model.applyYuhaiinUpdate() }
                            .yuhaiinActionButtonStyle()
                            .disabled(model.updateStatusIsRunning || update.assetURL?.isEmpty != false)
                    } else {
                        Text(update.reason.isEmpty ? L("settings.noUpdate") : update.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let status = model.yuhaiinUpdateStatus, status.running {
                    ProgressView(value: Double(status.progress), total: 100) {
                        Text(L("settings.updateProgress", status.stage))
                    }
                }
            }

        case .diagnostics:
            SettingsCard(selection.title, symbol: selection.symbol) {
                SettingsDiagnosticRow(title: L("diagnostics.appVersion"), value: "\(model.appVersion) (\(model.appBuild))")
                SettingsDiagnosticRow(title: L("diagnostics.appSignature"), value: model.appSignatureStatus)
                SettingsDiagnosticRow(
                    title: L("diagnostics.osArchitecture"),
                    value: "\(ProcessInfo.processInfo.operatingSystemVersionString) / \(model.diagnostics["architecture"] ?? "--")"
                )
                SettingsDiagnosticRow(title: L("diagnostics.supervisorPID"), value: model.diagnostics["supervisorPID"] ?? "--")
                SettingsDiagnosticRow(title: L("diagnostics.yuhaiinPID"), value: model.diagnostics["childPID"] ?? "--")
                SettingsDiagnosticRow(title: L("diagnostics.supervisorUID"), value: model.diagnostics["supervisorUID"] ?? "--")
                SettingsDiagnosticRow(title: L("diagnostics.legacyService"), value: model.diagnostics["legacyServiceInstalled"] ?? L("common.unknown"))
                SettingsDiagnosticRow(title: L("diagnostics.address"), value: model.diagnostics["host"] ?? model.apiBaseAddress)
                SettingsDiagnosticRow(title: L("diagnostics.dataPath"), value: model.diagnostics["dataPath"] ?? "--")
                if model.hasLegacyService {
                    Text(L("diagnostics.legacyDetected"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(L("diagnostics.migrateLegacy")) { showMigrationConfirmation = true }
                        .yuhaiinActionButtonStyle()
                        .disabled(model.isRunning || model.isBusy)
                }
                HStack {
                    Button(L("diagnostics.refresh")) { model.refreshDiagnostics() }
                        .yuhaiinActionButtonStyle(prominent: true)
                    Button(L("diagnostics.export")) { model.exportDiagnostics() }
                        .yuhaiinActionButtonStyle()
                }
                if !model.recentLogs.isEmpty {
                    Text(model.recentLogs)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(8)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if !model.lastError.isEmpty {
                    Text(model.lastError)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }
}

private struct SettingsDiagnosticRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 16)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}
