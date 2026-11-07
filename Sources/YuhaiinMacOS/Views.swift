import SwiftUI
import UniformTypeIdentifiers

// MARK: - Symbols

/// Returns an SF Symbols 6+ name on macOS 15 and later, and an older
/// equivalent on earlier systems where the new name would render blank.
func modernSymbol(_ modern: String, fallback: String) -> String {
    if #available(macOS 15.0, *) {
        return modern
    }
    return fallback
}

private enum Motion {
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
    static let quick = Animation.spring(response: 0.25, dampingFraction: 0.9)
    static let numbers = Animation.easeOut(duration: 0.35)
    static let ambient = Animation.easeInOut(duration: 0.8)
}

extension YuhaiinServiceState {
    var tint: Color {
        switch self {
        case .running: return .green
        case .starting, .stopping: return .blue
        case .failed: return .red
        case .awaitingApproval: return .orange
        case .stopped, .unavailable: return .secondary
        }
    }
}

// MARK: - Shared modifiers

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

    /// A material card with a hairline edge and a soft shadow.
    func yuhaiinCard(cornerRadius: CGFloat = 20) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.28), .white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            }
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    @ViewBuilder
    func yuhaiinActionButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            // Keep the control layer neutral. `.glassProminent` inherits the
            // system accent color and becomes a saturated blue block in this
            // app's light and dark appearances.
            buttonStyle(.glass)
                .fontWeight(prominent ? .semibold : .regular)
        } else {
            buttonStyle(.bordered)
                .fontWeight(prominent ? .semibold : .regular)
        }
    }

    /// Animated rolling digits for rate and version text.
    func numericTransition() -> some View {
        contentTransition(.numericText())
    }
}

/// Status symbol that morphs between states and spins while yuhaiin is
/// starting or stopping.
private struct StateSymbol: View {
    let state: YuhaiinServiceState

    var body: some View {
        Image(systemName: state.symbol)
            .symbolRenderingMode(.hierarchical)
            .modifier(StateSymbolEffects(state: state))
    }
}

private struct StateSymbolEffects: ViewModifier {
    let state: YuhaiinServiceState

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer)))
                .symbolEffect(.rotate, options: .repeating, isActive: state.isTransitioning)
                .symbolEffect(.pulse, options: .repeating, isActive: state == .awaitingApproval)
        } else if #available(macOS 14.0, *) {
            content
                .contentTransition(.symbolEffect(.replace.downUp.byLayer))
                .symbolEffect(
                    .pulse,
                    options: .repeating,
                    isActive: state.isTransitioning || state == .awaitingApproval
                )
        } else {
            content
        }
    }
}

/// Bounces a symbol whenever `trigger` changes (macOS 14+).
private struct BounceOnChange<Value: Equatable>: ViewModifier {
    let trigger: Value

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.symbolEffect(.bounce, value: trigger)
        } else {
            content
        }
    }
}

/// Large status badge with a soft halo that breathes while yuhaiin runs.
private struct StatusBadge: View {
    let state: YuhaiinServiceState
    var size: CGFloat = 36
    @State private var breathe = false

    var body: some View {
        ZStack {
            Circle()
                .fill(state.tint.opacity(0.14))
            Circle()
                .strokeBorder(state.tint.opacity(state == .running ? 0.35 : 0), lineWidth: 1)
                .scaleEffect(breathe && state == .running ? 1.18 : 1)
                .opacity(breathe && state == .running ? 0 : 1)
            StateSymbol(state: state)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(state.tint)
        }
        .frame(width: size, height: size)
        .animation(Motion.spring, value: state)
        .onAppear { startBreathing() }
        .onChange(of: state) { _ in startBreathing() }
    }

    private func startBreathing() {
        breathe = false
        guard state == .running else { return }
        withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
            breathe = true
        }
    }
}

private struct MenuBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuBarRow(configuration: configuration)
    }
}

private struct MenuBarRow: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .labelStyle(MenuRowLabelStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(fillOpacity))
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.quick, value: hovering)
            .animation(Motion.quick, value: configuration.isPressed)
            .onHover { hovering = $0 && isEnabled }
    }

    private var fillOpacity: Double {
        if configuration.isPressed { return 0.12 }
        return hovering ? 0.07 : 0
    }
}

private struct MenuRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            configuration.title
        }
    }
}

// MARK: - Menu bar

struct StatusLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            StateSymbol(state: model.state)
            if model.showSpeed && model.isRunning {
                Text("↓ \(model.formattedDownloadRate) ↑ \(model.formattedUploadRate)")
                    .font(.system(.caption, design: .monospaced))
                    .monospacedDigit()
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                StatusBadge(state: model.state, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.state.title)
                        .font(.headline)
                        .contentTransition(.opacity)
                    Text(model.apiAvailable ? L("dashboard.apiConnected") : L("dashboard.apiWaiting"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                Spacer()
            }
            .padding(12)
            .yuhaiinGlass(cornerRadius: 16)

            if model.isRunning {
                HStack(spacing: 8) {
                    MenuMetric(symbol: "arrow.down.circle.fill", value: model.formattedDownloadRate, tint: .blue)
                    MenuMetric(symbol: "arrow.up.circle.fill", value: model.formattedUploadRate, tint: .mint)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()
                .padding(.vertical, 2)

            VStack(spacing: 2) {
                Button {
                    model.isRunning ? model.stop() : model.start()
                } label: {
                    Label(
                        model.isRunning ? L("menu.stopYuhaiin") : L("menu.startYuhaiin"),
                        systemImage: model.isRunning ? "stop.fill" : "play.fill"
                    )
                }
                .disabled(model.isBusy)

                Button {
                    model.openControlPage()
                } label: {
                    Label(L("common.openControlPage"), systemImage: "globe")
                }
                .disabled(model.isBusy)

                Button {
                    updater.checkForUpdates()
                } label: {
                    Label(L("menu.checkAppUpdates"), systemImage: "arrow.down.app")
                }
                .disabled(!updater.canCheckForUpdates)

                Button {
                    model.checkYuhaiinUpdate()
                } label: {
                    Label(
                        L("menu.checkYuhaiinUpdates"),
                        systemImage: modernSymbol("arrow.trianglehead.2.clockwise.rotate.90", fallback: "arrow.triangle.2.circlepath")
                    )
                }
                .disabled(!model.isRunning || model.updateStatusIsRunning)

                Button {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label(L("menu.openMainWindow"), systemImage: "macwindow")
                }
            }

            Divider()
                .padding(.vertical, 2)

            VStack(spacing: 2) {
                Button {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label(L("menu.settings"), systemImage: "gearshape")
                }

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label(L("menu.quit"), systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .buttonStyle(MenuBarButtonStyle())
        .padding(12)
        .frame(width: 300)
        .animation(Motion.spring, value: model.state)
    }
}

private struct MenuMetric: View {
    let symbol: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
            Text(value)
                .monospacedDigit()
                .numericTransition()
                .animation(Motion.numbers, value: value)
        }
        .font(.system(.caption, design: .rounded).weight(.medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(0.1), in: Capsule())
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Yuhaiin")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        Text(L("dashboard.subtitle"))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 7) {
                        Circle()
                            .fill(model.state.tint)
                            .frame(width: 7, height: 7)
                            .shadow(color: model.state.tint.opacity(0.7), radius: model.isRunning ? 4 : 0)
                        Text(model.state.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .yuhaiinGlass(cornerRadius: 14)
                }

                HStack(spacing: 12) {
                    MetricCard(
                        title: L("metrics.download"),
                        value: model.formattedDownloadRate,
                        symbol: "arrow.down.circle.fill",
                        tint: .blue,
                        active: model.isRunning
                    )
                    MetricCard(
                        title: L("metrics.upload"),
                        value: model.formattedUploadRate,
                        symbol: "arrow.up.circle.fill",
                        tint: .mint,
                        active: model.isRunning
                    )
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 14) {
                        StatusBadge(state: model.state, size: 44)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.state.title)
                                .font(.title3.weight(.semibold))
                                .contentTransition(.opacity)
                            Text(model.apiAvailable ? L("dashboard.apiConnected") : L("dashboard.apiWaiting"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .contentTransition(.opacity)
                        }
                        Spacer()
                        if model.isBusy {
                            ProgressView()
                                .controlSize(.small)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }

                    Divider()

                    HStack(spacing: 10) {
                        Button {
                            model.isRunning ? model.stop() : model.start()
                        } label: {
                            Label(
                                model.isRunning ? L("common.stop") : L("common.start"),
                                systemImage: model.isRunning ? "stop.fill" : "play.fill"
                            )
                            .modifier(BounceOnChange(trigger: model.isRunning))
                        }
                        .yuhaiinActionButtonStyle(prominent: true)
                        .controlSize(.large)
                        .disabled(model.isBusy)

                        Button {
                            model.openControlPage()
                        } label: {
                            Label(L("common.openControlPage"), systemImage: "globe")
                        }
                        .yuhaiinActionButtonStyle()
                        .controlSize(.large)
                        .disabled(model.isBusy)
                    }
                }
                .padding(20)
                .yuhaiinCard(cornerRadius: 22)

                if !model.lastError.isEmpty {
                    ErrorBanner(message: model.lastError)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                VStack(spacing: 8) {
                    HStack {
                        Label(L("dashboard.yuhaiinVersion", model.yuhaiinVersion), systemImage: "shippingbox")
                        Spacer()
                        Label(
                            L("dashboard.localhostAPI", model.apiAvailable ? L("common.available") : L("common.unavailable")),
                            systemImage: model.apiAvailable ? "checkmark.circle" : "xmark.circle"
                        )
                    }

                    HStack {
                        Label(
                            updater.isConfigured ? L("dashboard.appUpdatesConfigured") : L("dashboard.appUpdatesNotConfigured"),
                            systemImage: updater.isConfigured ? "arrow.down.app" : "questionmark.app"
                        )
                        Spacer()
                        Button(L("common.checkForUpdates")) {
                            updater.checkForUpdates()
                        }
                        .buttonStyle(.link)
                        .disabled(!updater.canCheckForUpdates)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
            .padding(24)
            .animation(Motion.spring, value: model.state)
            .animation(Motion.spring, value: model.lastError)
        }
        .background {
            AmbientBackground(tint: model.isRunning ? .green : .accentColor)
        }
        .frame(minWidth: 540, minHeight: 380)
    }
}

/// Window background with a slow tint shift that follows the service state.
private struct AmbientBackground: View {
    let tint: Color

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [tint.opacity(0.16), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 480
            )
            RadialGradient(
                colors: [tint.opacity(0.06), .clear],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
        .animation(Motion.ambient, value: tint)
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.hierarchical)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
        }
        .foregroundStyle(.orange)
        .font(.callout)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    var active: Bool = true
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.title2)
                    .foregroundStyle(active ? tint : Color.secondary)
                Text(title)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .numericTransition()
                .animation(Motion.numbers, value: value)
                .foregroundStyle(active ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background {
            LinearGradient(
                colors: [tint.opacity(active ? 0.12 : 0.04), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .yuhaiinCard(cornerRadius: 20)
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(Motion.quick, value: hovering)
        .animation(Motion.ambient, value: active)
        .onHover { hovering = $0 }
    }
}

// MARK: - Settings

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
        case .service: return "gearshape.2.fill"
        case .statusBar: return "gauge.with.dots.needle.67percent"
        case .controlPage: return "globe"
        case .runtime: return "shippingbox.fill"
        case .authentication: return modernSymbol("key.horizontal.fill", fallback: "key.fill")
        case .appUpdates: return "arrow.down.to.line"
        case .yuhaiinUpdates: return modernSymbol("arrow.trianglehead.2.clockwise.rotate.90", fallback: "arrow.triangle.2.circlepath")
        case .diagnostics: return "stethoscope"
        }
    }

    var tint: Color {
        switch self {
        case .service: return .gray
        case .statusBar: return .indigo
        case .controlPage: return .blue
        case .runtime: return .purple
        case .authentication: return .orange
        case .appUpdates: return .teal
        case .yuhaiinUpdates: return .green
        case .diagnostics: return .pink
        }
    }
}

/// System Settings–style tinted squircle icon.
private struct SectionIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        // The sidebar applies its own icon sizing, which overrides a font set
        // on the symbol. Drawing it resizable inside the squircle keeps the
        // glyph within the frame at any row size.
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .overlay {
                Image(systemName: symbol)
                    .resizable()
                    .symbolRenderingMode(.monochrome)
                    .fontWeight(.semibold)
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .padding(size * 0.2)
            }
            .frame(width: size, height: size)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
            }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)

            Divider()

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .yuhaiinCard(cornerRadius: 22)
    }
}

private struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.13), in: Capsule())
            .contentTransition(.opacity)
    }
}

private struct FootnoteText: View {
    let text: String
    var warning = false

    init(_ text: String, warning: Bool = false) {
        self.text = text
        self.warning = warning
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(warning ? Color.orange : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
                Label {
                    Text(section.title)
                } icon: {
                    SectionIcon(symbol: section.symbol, tint: section.tint)
                }
                .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .navigationTitle("Yuhaiin")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 12) {
                        SectionIcon(symbol: selection.symbol, tint: selection.tint, size: 34)
                            .modifier(BounceOnChange(trigger: selection))
                        Text(selection.title)
                            .font(.system(.title2, design: .rounded).weight(.bold))
                        Spacer()
                    }

                    settingsContent
                        .id(selection)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 10)),
                                removal: .opacity
                            )
                        )
                }
                .padding(28)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(Motion.spring, value: selection)
            }
            .background {
                AmbientBackground(tint: selection.tint)
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
            SettingsCard(selection.title) {
                HStack {
                    Label(L("settings.supervisor"), systemImage: "lock.shield")
                    Spacer()
                    StatusPill(
                        text: model.supervisorAuthorized ? L("common.authorized") : L("common.notAuthorized"),
                        tint: model.supervisorAuthorized ? .green : .orange
                    )
                }
                if !model.supervisorAuthorized {
                    HStack {
                        Button(L("settings.installSupervisor")) { model.installSupervisor() }
                            .yuhaiinActionButtonStyle(prominent: true)
                        Button(L("settings.openLoginItems")) { model.openSystemLoginItems() }
                            .yuhaiinActionButtonStyle()
                    }
                    .transition(.opacity)
                } else {
                    Button(role: .destructive) {
                        showUninstallConfirmation = true
                    } label: {
                        Label(L("settings.uninstallSupervisor"), systemImage: "trash")
                    }
                    .foregroundStyle(.red)
                    .yuhaiinActionButtonStyle()
                    .transition(.opacity)
                }
                Divider()
                Toggle(L("settings.launchAtLogin"), isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
                Toggle(L("settings.autoStartYuhaiin"), isOn: $model.autoStartYuhaiin)
                    .toggleStyle(.switch)
                FootnoteText(L("settings.exitBehavior"))
            }
            .animation(Motion.spring, value: model.supervisorAuthorized)

        case .statusBar:
            SettingsCard(selection.title) {
                Toggle(L("settings.showSpeed"), isOn: $model.showSpeed)
                    .toggleStyle(.switch)
            }

        case .controlPage:
            SettingsCard(selection.title) {
                HStack {
                    Text(L("settings.port"))
                    Spacer()
                    TextField("50051", text: $model.apiPortText)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.applyAPIPort() }
                    Button(L("common.apply")) { model.applyAPIPort() }
                        .yuhaiinActionButtonStyle(prominent: true)
                }
                HStack {
                    Text(L("settings.address"))
                    Spacer()
                    Text(model.apiBaseAddress)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button {
                    model.openControlPage()
                } label: {
                    Label(L("common.openControlPage"), systemImage: "globe")
                }
                .yuhaiinActionButtonStyle()
                FootnoteText(
                    model.apiAuthenticationEnabled
                        ? L("settings.localhostAuthEnabled")
                        : L("settings.localhostAuthDisabled"),
                    warning: !model.apiAuthenticationEnabled
                )
            }

        case .runtime:
            SettingsCard(selection.title) {
                TextField(L("settings.customBinaryPath"), text: $model.customBinaryPathText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.applyCustomBinaryPath() }
                HStack {
                    Button(L("settings.applyBinaryPath")) { model.applyCustomBinaryPath() }
                        .yuhaiinActionButtonStyle(prominent: true)
                    Button(L("settings.useBundledBinary")) { model.useBundledBinary() }
                        .yuhaiinActionButtonStyle()
                }
                HStack {
                    Button {
                        showBinaryImporter = true
                    } label: {
                        Label(L("settings.uploadBinary"), systemImage: "doc.badge.arrow.up")
                    }
                    .yuhaiinActionButtonStyle()
                    .disabled(model.isBusy)
                    if model.binaryUploadInProgress {
                        ProgressView().controlSize(.small)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                if model.uploadedBinaryInstalled {
                    Label(L("settings.uploadedBinaryActive"), systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
                FootnoteText(L("settings.binaryPathNote"))
                FootnoteText(L("settings.binaryUploadNote"))
            }
            .animation(Motion.spring, value: model.binaryUploadInProgress)
            .animation(Motion.spring, value: model.uploadedBinaryInstalled)

        case .authentication:
            SettingsCard(selection.title) {
                Toggle(L("settings.enableBasicAuth"), isOn: $model.apiAuthenticationEnabled)
                    .toggleStyle(.switch)
                if model.apiAuthenticationEnabled {
                    VStack(spacing: 8) {
                        TextField(L("settings.username"), text: $model.apiUsernameText)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.username)
                        SecureField(L("settings.password"), text: $model.apiPasswordText)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.password)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                Button(L("settings.applyAuth")) { model.applyAPIAuthentication() }
                    .yuhaiinActionButtonStyle(prominent: true)
                FootnoteText(L("settings.authApplyNote"))
                FootnoteText(
                    model.apiAuthenticationEnabled
                        ? L("settings.authEnabledNote")
                        : L("settings.authDisabledNote"),
                    warning: !model.apiAuthenticationEnabled
                )
            }
            .animation(Motion.spring, value: model.apiAuthenticationEnabled)

        case .appUpdates:
            SettingsCard(selection.title) {
                HStack {
                    Label(L("settings.sparkleFeed"), systemImage: "antenna.radiowaves.left.and.right")
                    Spacer()
                    StatusPill(
                        text: updater.isConfigured ? L("common.configured") : L("common.notConfigured"),
                        tint: updater.isConfigured ? .green : .secondary
                    )
                }
                Button(L("settings.checkAppUpdates")) { updater.checkForUpdates() }
                    .yuhaiinActionButtonStyle(prominent: true)
                    .disabled(!updater.canCheckForUpdates)
                if !updater.isConfigured {
                    FootnoteText(L("settings.sparkleNotConfigured"))
                }
            }

        case .yuhaiinUpdates:
            SettingsCard(selection.title) {
                HStack {
                    Text(L("settings.currentVersion"))
                    Spacer()
                    Text(model.yuhaiinVersion)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Button(L("settings.checkYuhaiinUpdates")) { model.checkYuhaiinUpdate() }
                    .yuhaiinActionButtonStyle(prominent: true)
                    .disabled(!model.isRunning || model.updateStatusIsRunning)
                if let update = model.yuhaiinUpdate {
                    Group {
                        if update.updateAvailable {
                            Label(L("settings.updateAvailable", update.targetVersion), systemImage: "sparkles")
                                .foregroundStyle(.orange)
                            Button(L("settings.installYuhaiinUpdate")) { model.applyYuhaiinUpdate() }
                                .yuhaiinActionButtonStyle()
                                .disabled(model.updateStatusIsRunning || update.assetURL?.isEmpty != false)
                        } else {
                            FootnoteText(update.reason.isEmpty ? L("settings.noUpdate") : update.reason)
                        }
                    }
                    .transition(.opacity)
                }
                if let status = model.yuhaiinUpdateStatus, status.running {
                    ProgressView(value: Double(min(max(status.progress, 0), 100)), total: 100) {
                        Text(L("settings.updateProgress", status.stage))
                    }
                    .animation(Motion.numbers, value: status.progress)
                    .transition(.opacity)
                }
            }
            .animation(Motion.spring, value: model.updateStatusIsRunning)
            .animation(Motion.spring, value: model.yuhaiinUpdate?.updateAvailable)

        case .diagnostics:
            SettingsCard(selection.title) {
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
                    FootnoteText(L("diagnostics.legacyDetected"), warning: true)
                    Button(L("diagnostics.migrateLegacy")) { showMigrationConfirmation = true }
                        .yuhaiinActionButtonStyle()
                        .disabled(model.isRunning || model.isBusy)
                }
                HStack {
                    Button {
                        model.refreshDiagnostics()
                    } label: {
                        Label(L("diagnostics.refresh"), systemImage: "arrow.clockwise")
                    }
                    .yuhaiinActionButtonStyle(prominent: true)
                    Button {
                        model.exportDiagnostics()
                    } label: {
                        Label(L("diagnostics.export"), systemImage: "square.and.arrow.up")
                    }
                    .yuhaiinActionButtonStyle()
                }
                if !model.recentLogs.isEmpty {
                    ScrollView {
                        Text(model.recentLogs)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .padding(12)
                    .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if !model.lastError.isEmpty {
                    ErrorBanner(message: model.lastError)
                        .transition(.opacity)
                }
            }
            .animation(Motion.spring, value: model.lastError)
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
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
    }
}
