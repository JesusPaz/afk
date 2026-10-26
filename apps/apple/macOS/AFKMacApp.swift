import SwiftUI
import CoreImage.CIFilterBuiltins
import AFKCore
import AFKHost
import UniformTypeIdentifiers

private struct SessionDrag: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "com.jesuspaz.afk.session", conformingTo: .data))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var host: HostController?
    private var waitingForTermination = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if waitingForTermination { return .terminateLater }
        guard let host, host.sessions.contains(where: \.running) else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = L10n.text("¿Detener AFK y sus sesiones?"); alert.informativeText = L10n.text("Se cerrarán los procesos de estas sesiones. Cerrar solo la ventana los mantiene activos.")
        alert.addButton(withTitle: L10n.text("Detener AFK")); alert.addButton(withTitle: L10n.text("Cancelar"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        waitingForTermination = true
        host.disconnect()
        host.sessions.forEach { $0.terminate() }
        Task { @MainActor in
            if !(await waitForExit(host, seconds: 2)) {
                for session in host.sessions where session.running { host.forceClose(id: session.id) }
            }
            let stopped = await waitForExit(host, seconds: 3)
            if stopped { host.shutdown() }
            waitingForTermination = false
            sender.reply(toApplicationShouldTerminate: stopped)
            if !stopped {
                let failure = NSAlert()
                failure.messageText = L10n.text("No se pudo confirmar el cierre de todas las terminales")
                failure.informativeText = L10n.text("AFK seguirá abierto para que puedas revisar las sesiones que aún se están cerrando. El acceso remoto quedó desconectado.")
                failure.addButton(withTitle: L10n.text("Aceptar"))
                failure.runModal()
            }
        }
        return .terminateLater
    }
    @MainActor private func waitForExit(_ host: HostController, seconds: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while host.sessions.contains(where: \.running) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}

@main
struct AFKMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var host = HostController(historyDirectory: TerminalHistory.defaultDirectory)
    var body: some Scene {
        WindowGroup("AFK") { MacWorkspace(host: host).onAppear { delegate.host = host } }
            .defaultSize(width: 1040, height: 720)
            .commands { SessionWorkspaceCommands() }
        Settings { MacSettings() }
    }
}

private struct MacSettings: View {
    @AppStorage(HostController.sessionLimitKey) private var sessionLimit = HostController.defaultSessionLimit
    var body: some View {
        Form {
            Stepper(value: $sessionLimit, in: HostController.sessionLimitRange) {
                LabeledContent(L10n.text("Sesiones abiertas a la vez"), value: "\(sessionLimit)")
            }
            Text(L10n.text("Cada sesión mantiene su shell, su pantalla y su grabación en memoria. Las sesiones terminadas no cuentan."))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 420)
    }
}

private struct WorkspaceNavigation {
    let createSession: () -> Void
    let closeSession: (() -> Void)?
    let step: (Int) -> Void
    let jump: (Int) -> Void
    let profiles: [String]
    let selectProfile: (Int) -> Void
    let stepProfile: (Int) -> Void
    let quickOpen: () -> Void
}
private struct WorkspaceNavigationKey: FocusedValueKey {
    typealias Value = WorkspaceNavigation
}
private extension FocusedValues {
    var workspace: WorkspaceNavigation? {
        get { self[WorkspaceNavigationKey.self] }
        set { self[WorkspaceNavigationKey.self] = newValue }
    }
}
private struct SessionWorkspaceCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.text("Nueva sesión")) { workspace?.createSession() }.keyboardShortcut("n")
                .disabled(workspace == nil)
        }
        // ⌘W closes the terminal, like a tab in Terminal; the window moves to ⇧⌘W.
        CommandGroup(replacing: .saveItem) {
            // Without a selected session (Settings, empty profile) ⌘W still closes the window.
            Button(L10n.text("Cerrar sesión…")) {
                if let close = workspace?.closeSession { close() } else { NSApp.keyWindow?.performClose(nil) }
            }.keyboardShortcut("w")
            Button(L10n.text("Cerrar ventana")) { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandMenu(L10n.text("Ir")) {
            Button(L10n.text("Ir a terminal…")) { workspace?.quickOpen() }.keyboardShortcut("k")
            Divider()
            Button(L10n.text("Terminal anterior")) { workspace?.step(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button(L10n.text("Terminal siguiente")) { workspace?.step(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button(L10n.format("Terminal %lld", number)) { workspace?.jump(number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
            Divider()
            Button(L10n.text("Perfil anterior")) { workspace?.stepProfile(-1) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button(L10n.text("Perfil siguiente")) { workspace?.stepProfile(1) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            ForEach(Array((workspace?.profiles ?? []).prefix(9).enumerated()), id: \.offset) { index, name in
                Button(name) { workspace?.selectProfile(index) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .control])
            }
        }
    }
}

private enum WorkspaceSheet: String, Identifiable {
    case pair, devices, server, permissions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pair: return L10n.text("Vincular iPhone")
        case .devices: return L10n.text("Dispositivos")
        case .server: return L10n.text("Conexión")
        case .permissions: return L10n.text("Permisos de la sesión")
        }
    }
}

struct MacWorkspace: View {
    @ObservedObject var host: HostController
    @AppStorage("workspaceProfile") private var profile: WorkspaceProfile = .personal
    @State private var selected: String?
    @AppStorage("relayURL") private var server = Bundle.main.object(forInfoDictionaryKey: "AFKRelayURL") as? String ?? "http://127.0.0.1:8787"
    @State private var sheet: WorkspaceSheet?
    @State private var showingHistory = false
    @State private var permissionSession: HostSession?
    @State private var renaming: HostSession?
    @State private var editingGroup: SessionGroup?
    @State private var showingGroupEditor = false
    @State private var showingProfileEditor = false
    @State private var newProfileName = ""
    @State private var targetedGroup: String?
    @State private var closingSession: HostSession?
    @State private var forceClosing = false
    @AppStorage("collapsedSessionGroups") private var collapsedGroupIDs = ""
    private var collapsedGroups: Set<String> { Set(collapsedGroupIDs.split(separator: ",").map(String.init)) }
    @State private var showingHidden = false
    @State private var showingEnded = false
    @State private var lastHidden: HostSession?
    @State private var removedGroup: SessionGroup?
    @State private var removedGroupSessions: [String] = []
    @State private var removedGroupProfile: WorkspaceProfile = .personal
    @State private var emptyTitle: String?
    @State private var showingSwitcher = false
    @State private var pendingSelection: String?
    @State private var lastSelection: [WorkspaceProfile: String] = [:]

    // Sidebar order: ungrouped sessions first, then groups.
    private var navigationOrder: [HostSession] {
        visible(groupID: nil) + profileGroups.flatMap { visible(groupID: $0.id) }
    }
    private func open(_ session: HostSession) {
        expand(session.groupID)
        // Switching profile clears the selection, so select once that has happened.
        if session.profile != profile { pendingSelection = session.id; profile = session.profile }
        else { selected = session.id }
    }
    private func expand(_ groupID: String?) {
        guard let groupID, collapsedGroups.contains(groupID) else { return }
        collapsedGroupIDs = collapsedGroups.subtracting([groupID]).sorted().joined(separator: ",")
    }
    private func step(_ offset: Int) {
        let order = navigationOrder
        guard !order.isEmpty else { return }
        let current = order.firstIndex { $0.id == selected } ?? (offset > 0 ? -1 : order.count)
        open(order[(current + offset + order.count) % order.count])
    }
    private var navigation: WorkspaceNavigation {
        WorkspaceNavigation(
            createSession: { createSession(groupID: host.sessions.first { $0.id == selected }?.groupID) },
            closeSession: profileSessions.first { $0.id == selected }.map { session in { requestClose(session) } },
            step: step,
            jump: { index in if navigationOrder.indices.contains(index) { open(navigationOrder[index]) } },
            profiles: host.profiles.map(profileName),
            selectProfile: { index in if host.profiles.indices.contains(index) { profile = host.profiles[index] } },
            stepProfile: { offset in
                guard let current = host.profiles.firstIndex(of: profile) else { return }
                profile = host.profiles[(current + offset + host.profiles.count) % host.profiles.count]
            },
            quickOpen: { showingSwitcher = true })
    }

    private func createSession(groupID: String? = nil) {
        guard let session = host.create(profile: profile) else { return }
        if let groupID { host.moveSession(id: session.id, groupID: groupID) }
        selected = session.id
    }
    private func group(for session: HostSession) -> SessionGroup? {
        host.groups.first { $0.id == session.groupID }
    }
    private func hide(_ session: HostSession) {
        if selected == session.id { selected = nil; emptyTitle = session.name }
        host.setHidden(id: session.id, hidden: true)
        lastHidden = session
    }
    private func remove(_ session: HostSession) {
        if selected == session.id { selected = nil; emptyTitle = session.name }
        if forceClosing { host.forceClose(id: session.id) }
        else if session.running { host.closeAndRemove(id: session.id) }
        else { host.removeEnded(id: session.id) }
    }
    private func profileName(_ profile: WorkspaceProfile) -> String { host.profileName(profile) }
    private var profilePicker: some View {
        Picker(L10n.text("Perfil"), selection: $profile) {
            ForEach(host.profiles, id: \.self) { profile in
                Text(profileName(profile)).tag(profile)
            }
        }.accessibilityIdentifier("workspace-profile")
    }
    private func dropHighlight(_ targeted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(targeted ? 0.18 : 0))
            .strokeBorder(Color.accentColor.opacity(targeted ? 0.7 : 0), lineWidth: 1.5)
            .animation(.easeOut(duration: 0.12), value: targeted)
    }
    private var profileSessions: [HostSession] { host.sessions.filter { $0.profile == profile } }
    private var profileGroups: [SessionGroup] { host.groups.filter { host.profile(forGroup: $0.id) == profile } }
    private var hidden: [HostSession] { profileSessions.filter(\.isHidden) }
    private var ended: [HostSession] { profileSessions.filter { !$0.running && !$0.isHidden } }
    private func visible(groupID: String?) -> [HostSession] {
        profileSessions.filter { $0.running && !$0.isHidden && $0.groupID == groupID }
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                // Like Reminders: loose items sit at the top without a header.
                ForEach(visible(groupID: nil)) { session in sessionRow(session) }
                ForEach(profileGroups) { group in
                    DisclosureGroup(isExpanded: Binding(
                        get: { !collapsedGroups.contains(group.id) },
                        set: { expanded in
                            var ids = collapsedGroups
                            if expanded { ids.remove(group.id) } else { ids.insert(group.id) }
                            collapsedGroupIDs = ids.sorted().joined(separator: ",")
                        }
                    )) {
                        ForEach(visible(groupID: group.id)) { session in sessionRow(session) }
                        if visible(groupID: group.id).isEmpty {
                            Button(L10n.text("Nueva sesión")) { createSession(groupID: group.id) }
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        HStack(spacing: 7) {
                            SessionGroupMark(group: group)
                            Text(group.name).lineLimit(1)
                            Spacer(minLength: 2)
                            if collapsedGroups.contains(group.id) {
                                Text(visible(groupID: group.id).count.formatted()).foregroundStyle(.secondary).font(.caption.monospacedDigit())
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3).padding(.horizontal, 4)
                        .background(dropHighlight(targetedGroup == group.id))
                        .dropDestination(for: SessionDrag.self) { items, _ in
                            drop(items, into: group.id)
                        } isTargeted: { targetedGroup = $0 ? group.id : nil }
                        .contextMenu { groupActions(group) }
                    }
                }
                if !hidden.isEmpty {
                    DisclosureGroup(isExpanded: $showingHidden) {
                        ForEach(hidden) { session in
                            HStack {
                                sessionRow(session)
                                Button(L10n.text("Mostrar")) {
                                    host.setHidden(id: session.id, hidden: false)
                                    selected = session.id
                                }.buttonStyle(.borderless)
                            }.selectionDisabled()
                        }
                    } label: { Label(L10n.text("Ocultas") + " · " + hidden.count.formatted(), systemImage: "eye.slash") }
                }
                if !ended.isEmpty {
                    DisclosureGroup(isExpanded: $showingEnded) {
                        ForEach(ended) { session in sessionRow(session) }
                    } label: { Label(L10n.text("Terminadas") + " · " + ended.count.formatted(), systemImage: "stop.circle") }
                }
            }
            .listStyle(.sidebar)
            // Dropping on empty sidebar space takes a session out of its group.
            .dropDestination(for: SessionDrag.self) { items, _ in
                drop(items, into: nil)
            } isTargeted: { targetedGroup = $0 ? "ungrouped" : nil }
            .overlay { dropHighlight(targetedGroup == "ungrouped").padding(4).allowsHitTesting(false) }
            .toolbar {
                // Like Calendar's sidebar buttons: secondary places stay one click away.
                ToolbarItemGroup {
                    Button { showingHistory = true } label: { Label(L10n.text("Historial guardado"), systemImage: "clock") }
                        .help(L10n.text("Historial guardado"))
                    Button { sheet = .devices } label: { Label(L10n.text("Dispositivos"), systemImage: "iphone") }
                        .help(L10n.text("Dispositivos"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    if let lastHidden {
                        HStack {
                            Text(L10n.text("Sesión oculta")).font(.caption)
                            Spacer()
                            Button(L10n.text("Deshacer")) {
                                host.setHidden(id: lastHidden.id, hidden: false)
                                self.lastHidden = nil
                            }
                        }
                    }
                    if let removedGroup {
                        HStack {
                            Text(L10n.text("Grupo eliminado")).font(.caption)
                            Spacer()
                            Button(L10n.text("Deshacer")) {
                                host.restoreGroup(removedGroup, sessionIDs: removedGroupSessions, profile: removedGroupProfile)
                                self.removedGroup = nil
                            }
                        }
                    }
                    // The status opens its own settings, so the toolbar keeps two buttons and never overflows.
                    Button { sheet = .server } label: { RemoteAccessStatus(host: host, relay: host.relay) }
                        .help(L10n.text("Conexión")).padding(.top, 4)
                }.buttonStyle(.plain).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            ZStack {
                // Keep every live renderer attached, including hidden sessions.
                ForEach(host.sessions) { session in
                    LocalTerminalPane(session: session, active: session.profile == profile && session.id == selected && !session.isHidden && !session.closing && sheet == nil && !showingHistory && renaming == nil && !showingGroupEditor && !showingProfileEditor && !showingSwitcher && closingSession == nil,
                                      actions: { AnyView(sessionActions(session)) })
                        .opacity(session.profile == profile && session.id == selected ? 1 : 0)
                        .allowsHitTesting(session.profile == profile && session.id == selected)
                        .accessibilityHidden(session.profile != profile || session.id != selected)
                }
                if !profileSessions.contains(where: { $0.id == selected }) {
                    ContentUnavailableView {
                        Label(L10n.text("Elige una terminal"), systemImage: "terminal")
                    } description: {
                        if let emptyTitle { Text(emptyTitle).fontWeight(.medium) }
                        Text(L10n.text("Selecciona una sesión en la barra lateral o abre una nueva."))
                    } actions: {
                        Button(L10n.text("Nueva sesión")) { createSession() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .focusedSceneValue(\.workspace, navigation)
        .navigationTitle(host.sessions.first(where: { $0.id == selected })?.windowTitle ?? "AFK")
        .toolbar {
            // Profiles switch the whole workspace, like Calendar's Day/Week/Month control.
            ToolbarItem(placement: .principal) {
                if host.profiles.count <= 4 { profilePicker.pickerStyle(.segmented).labelsHidden().fixedSize() }
                else { profilePicker.pickerStyle(.menu).fixedSize() }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(L10n.text("Nueva sesión")) { navigation.createSession() }
                    Button(L10n.text("Nuevo grupo…")) { editingGroup = nil; showingGroupEditor = true }
                    Button(L10n.text("Nuevo perfil…")) { newProfileName = ""; showingProfileEditor = true }
                        .disabled(host.profiles.count >= 64)
                } label: { Label(L10n.text("Nueva sesión"), systemImage: "plus") } primaryAction: { navigation.createSession() }
                    .help(L10n.text("Nueva sesión junto a la actual (⌘N). Mantén pulsado para crear un grupo o perfil."))
                    .accessibilityIdentifier("new-session")
            }
        }
        .sheet(isPresented: $showingHistory) {
            SavedTerminalHistory(active: Set(host.sessions.filter(\.running).compactMap { $0.feed.history?.entry.id }))
        }
        .sheet(item: $sheet) { destination in
            MacConnectionSheet(host: host, server: $server, destination: destination,
                               session: destination == .permissions ? permissionSession : nil)
        }
        .sheet(isPresented: $showingSwitcher) {
            SessionSwitcher(host: host, currentProfile: profile, open: open)
        }
        .sheet(item: $renaming) { session in
            SessionNameEditor(session: session) { host.renameSession(id: session.id, label: $0) }
        }
        .alert(L10n.text("Nuevo perfil…"), isPresented: $showingProfileEditor) {
            TextField(L10n.text("Nombre"), text: $newProfileName)
            Button(L10n.text("Crear")) {
                if let created = host.createProfile(name: newProfileName) { profile = created }
            }.disabled(SessionMetadata.clean(newProfileName) == nil ||
                host.profiles.contains { profileName($0).localizedCaseInsensitiveCompare(SessionMetadata.clean(newProfileName) ?? "") == .orderedSame })
            Button(L10n.text("Cancelar"), role: .cancel) {}
        }
        .sheet(isPresented: $showingGroupEditor) {
            SessionGroupEditor(group: editingGroup) { name, symbol, color, emoji in
                if let group = editingGroup {
                    host.updateGroup(SessionGroup(id: group.id, name: name, symbol: symbol, color: color, emoji: emoji))
                } else { _ = host.createGroup(name: name, symbol: symbol, color: color, emoji: emoji, profile: profile) }
            }
        }
        .confirmationDialog(forceClosing ? L10n.text("¿Forzar cierre?") : L10n.text("¿Cerrar y quitar esta sesión?"),
                            isPresented: Binding(get: { closingSession != nil }, set: { if !$0 { closingSession = nil } }),
                            titleVisibility: .visible) {
            Button(forceClosing ? L10n.text("Forzar cierre") : L10n.text("Cerrar y quitar"), role: .destructive) {
                if let closingSession { remove(closingSession) }
                closingSession = nil
            }
            Button(L10n.text("Cancelar"), role: .cancel) { closingSession = nil }
        } message: {
            Text([closingSession.flatMap { group(for: $0)?.name }, closingSession?.name].compactMap { $0 }.joined(separator: " / ") + "\n" + L10n.text("Se detendrá la terminal y sus procesos vinculados. La grabación se conservará. Los servicios independientes y las tareas remotas pueden seguir activos."))
        }
        .alert(L10n.text("No se pudo completar la acción"), isPresented: Binding(
            get: { host.error != nil && sheet == nil }, set: { if !$0 { host.error = nil } }
        )) { Button(L10n.text("Aceptar")) { host.error = nil } } message: { Text(host.error ?? "") }
        .frame(minWidth: 860, minHeight: 520)
        .onAppear {
            if !host.profiles.contains(profile) { profile = .personal }
            if host.sessions.isEmpty { createSession() }
            else if selected == nil { selected = profileSessions.first(where: { !$0.isHidden && $0.running })?.id }
        }
        .task { await host.restoreConnection(server: server) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            host.checkConnection(force: true)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            host.checkConnection(force: true)
        }
        .onChange(of: host.sessions.map(\.id)) { _, next in
            if let selected, !next.contains(selected) { self.selected = nil }
        }
        .onChange(of: selected) { _, next in
            if let next { lastSelection[profile] = next }
        }
        .onChange(of: profile) { _, _ in
            // Come back to the terminal last used in this profile, or its first one.
            let remembered = lastSelection[profile].flatMap { id in navigationOrder.first { $0.id == id } }
            selected = pendingSelection ?? (remembered ?? navigationOrder.first)?.id
            pendingSelection = nil; emptyTitle = nil; lastHidden = nil; removedGroup = nil
        }
    }

    private func sessionRow(_ session: HostSession) -> some View {
        MacSessionRow(session: session, group: group(for: session),
                      disambiguate: host.sessions.filter { $0.name == session.name }.count > 1)
            .tag(session.id).contextMenu { sessionActions(session) }
            .draggable(SessionDrag(id: session.id)) { SessionDragPreview(session: session, group: group(for: session)) }
            .dropDestination(for: SessionDrag.self) { items, _ in
                drop(items, into: session.groupID)
            } isTargeted: { targetedGroup = $0 ? session.groupID ?? "ungrouped" : nil }
    }
    private func drop(_ items: [SessionDrag], into groupID: String?) -> Bool {
        targetedGroup = nil
        expand(groupID)
        return withAnimation(.snappy(duration: 0.25)) {
            host.dropSessions(items.map(\.id), groupID: groupID, profile: profile)
        }
    }
    @ViewBuilder private func sessionActions(_ session: HostSession) -> some View {
        Button(L10n.text("Renombrar…")) { renaming = session }
        if session.userLabel != nil {
            Button(L10n.text("Usar título automático")) { host.renameSession(id: session.id, label: nil) }
        }
        Menu(L10n.text("Mover a grupo")) {
            Button(L10n.text("Sin grupo")) { host.moveSession(id: session.id, groupID: nil) }
            ForEach(profileGroups) { group in
                Button { host.moveSession(id: session.id, groupID: group.id) } label: {
                    Label { Text(group.name) } icon: { SessionGroupMark(group: group) }
                }
            }
        }
        Menu(L10n.text("Mover a perfil")) {
            ForEach(host.profiles.filter { $0 != session.profile }, id: \.self) { destination in
                Button(profileName(destination)) {
                    if selected == session.id { selected = nil }
                    host.moveSession(id: session.id, profile: destination)
                }
            }
        }
        Menu(L10n.text("Ordenar sesión")) {
            Button(L10n.text("Subir")) { host.reorderSession(id: session.id, offset: -1) }
            Button(L10n.text("Bajar")) { host.reorderSession(id: session.id, offset: 1) }
        }
        if session.isHidden {
            Button(L10n.text("Mostrar en la barra lateral")) { host.setHidden(id: session.id, hidden: false) }
        } else {
            Button(L10n.text("Ocultar en este Mac")) { hide(session) }
        }
        Divider()
        Button(L10n.text("Permisos de la sesión…")) { permissionSession = session; sheet = .permissions }
            .accessibilityIdentifier("session-permissions")
        Divider()
        Button(session.closing ? L10n.text("Forzar cierre…") : session.running ? L10n.text("Cerrar y quitar…") : L10n.text("Quitar de la lista"),
               role: session.closing || session.running ? .destructive : nil) { requestClose(session) }
    }
    private func requestClose(_ session: HostSession) {
        forceClosing = session.closing
        if session.closing || session.running { closingSession = session } else { remove(session) }
    }
    @ViewBuilder private func groupActions(_ group: SessionGroup) -> some View {
        Button(L10n.text("Nueva sesión en este grupo")) { createSession(groupID: group.id) }
        Button(L10n.text("Editar grupo…")) { editingGroup = group; showingGroupEditor = true }
        Menu(L10n.text("Mover a perfil")) {
            ForEach(host.profiles.filter { $0 != host.profile(forGroup: group.id) }, id: \.self) { destination in
                Button(profileName(destination)) {
                    if host.sessions.contains(where: { $0.id == selected && $0.groupID == group.id }) { selected = nil }
                    host.moveGroup(id: group.id, profile: destination)
                }
            }
        }
        Button(L10n.text("Subir")) { host.reorderGroup(id: group.id, offset: -1) }
        Button(L10n.text("Bajar")) { host.reorderGroup(id: group.id, offset: 1) }
        Divider()
        Button(L10n.text("Eliminar grupo y conservar sesiones")) {
            removedGroup = group
            removedGroupProfile = host.profile(forGroup: group.id)
            removedGroupSessions = host.sessions.filter { $0.groupID == group.id }.map(\.id)
            host.deleteGroup(id: group.id)
        }
    }
}

private struct SessionDragPreview: View {
    @ObservedObject var session: HostSession
    let group: SessionGroup?
    var body: some View {
        HStack(spacing: 10) {
            SessionGroupMark(group: group)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name).fontWeight(.medium).lineLimit(1)
                if let context = session.context, !context.isEmpty {
                    Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(width: 240, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }
}

private struct SessionSwitcher: View {
    @ObservedObject var host: HostController
    let currentProfile: WorkspaceProfile
    let open: (HostSession) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool
    private var matches: [HostSession] {
        let running = host.sessions.filter { $0.running && !$0.closing }
        let live = running.filter { $0.profile == currentProfile } + running.filter { $0.profile != currentProfile }
        let terms = query.split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return live }
        return live.filter { session in
            let text = [session.name, session.context, host.groups.first { $0.id == session.groupID }?.name, host.profileName(session.profile)]
                .compactMap { $0 }.joined(separator: " ")
            return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
    }
    private func choose(_ index: Int) {
        let results = matches
        guard results.indices.contains(index) else { return }
        dismiss(); open(results[index])
    }
    var body: some View {
        VStack(spacing: 0) {
            TextField(L10n.text("Busca por nombre, carpeta, grupo o perfil"), text: $query)
                .textFieldStyle(.plain).font(.title3).padding(14).focused($focused)
                .onSubmit { choose(highlighted) }
                .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(matches.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                .onChange(of: query) { _, _ in highlighted = 0 }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, session in
                            Button { choose(index) } label: {
                                HStack(spacing: 10) {
                                    SessionGroupMark(group: host.groups.first { $0.id == session.groupID })
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.name).lineLimit(1)
                                        Text([host.profileName(session.profile), host.groups.first { $0.id == session.groupID }?.name, session.context]
                                            .compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(index == highlighted ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(index)
                        }
                        if matches.isEmpty {
                            Text(L10n.text("Ninguna terminal coincide")).foregroundStyle(.secondary).padding(20)
                        }
                    }.padding(6)
                }
                .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
            }
            .frame(height: 320)
        }
        .frame(width: 520)
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
    }
}

private struct MacSessionRow: View {
    @ObservedObject var session: HostSession
    let group: SessionGroup?
    let disambiguate: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SessionGroupMark(group: group).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name).fontWeight(.medium).lineLimit(2)
                HStack(spacing: 5) {
                    Text(session.closing ? L10n.text("Cerrando…") : !session.running ? L10n.text("Terminada") : session.lease.owner == "local" ? L10n.text("Escribiendo en este Mac") : session.lease.owner.isEmpty ? L10n.text("Solo lectura") : L10n.text("Control desde iPhone"))
                    if disambiguate { Text(String(session.id.prefix(4))).monospaced() }
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
        .help([session.name, session.context, session.userLabel == nil ? nil : session.reportedTitle].compactMap { $0 }.joined(separator: " · "))
        .accessibilityElement(children: .combine)
    }
}

private struct RemoteAccessStatus: View {
    @ObservedObject var host: HostController
    @ObservedObject var relay: SecureHostRelay
    private var title: String {
        if host.remoteAccessPaused { return L10n.text("Acceso remoto pausado") }
        if host.connecting || relay.status == L10n.text("Conectando…") { return L10n.text("Conectando…") }
        return relay.connected ? L10n.text("Acceso remoto conectado") : L10n.text("Acceso remoto desconectado")
    }
    var body: some View {
        ConnectionIndicator(title: title, connected: relay.connected)
    }
}

private struct MacConnectionSheet: View {
    @ObservedObject var host: HostController
    @Binding var server: String
    @State var destination: WorkspaceSheet
    var session: HostSession? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var revokeID: String?
    @State private var revokeAll = false
    @State private var upgradeIdentity = false
    @State private var copied = false
    @State private var candidate: PairingCandidate?
    @State private var approving = false
    @State private var completed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(destination.title).font(.title2.weight(.semibold))
                    Text(destination == .permissions ? (session?.name ?? "") : destination == .pair ? L10n.text("Tu misma terminal, también en el teléfono.") : destination == .devices ? L10n.text("Decide quién puede acceder a tus sesiones.") : L10n.text("El punto de encuentro entre tu Mac y tu iPhone."))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Button(L10n.text("Cerrar")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if destination == .pair { pairingContent }
                    else if destination == .devices { devicesContent }
                    else if destination == .permissions { sessionPermissionsContent }
                    else { serverContent }
                    if let error = host.error { InlineNotice(text: error) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: destination == .pair ? 570 : 420)
        }
        .frame(width: 540)
        .task(id: destination) { await prepare() }
        .onReceive(host.relay.$candidate) { candidate = $0 }
        .onDisappear { host.cancelPairing() }
        .onChange(of: destination) { old, next in
            if old == .pair && next != .pair { host.cancelPairing() }
        }
        .confirmationDialog(L10n.text("¿Proteger la identidad de este Mac?"), isPresented: $upgradeIdentity) {
            Button(L10n.text("Proteger y volver a vincular")) { Task { await host.upgradeIdentity(server: server) } }
        } message: { Text(L10n.text("Se retirarán los vínculos anteriores. Vuelve a vincular tus iPhones con un QR nuevo. Las terminales locales seguirán abiertas.")) }
        .confirmationDialog(L10n.text("¿Revocar todos los dispositivos?"), isPresented: $revokeAll) {
            Button(L10n.text("Revocar todos los dispositivos"), role: .destructive) { host.revokeAllDevices() }
        } message: { Text(L10n.text("Todos necesitarán una nueva invitación. Las terminales locales seguirán abiertas.")) }
        .confirmationDialog(L10n.text("¿Revocar el acceso de este iPhone?"), isPresented: Binding(get: { revokeID != nil }, set: { if !$0 { revokeID = nil } })) {
            Button(L10n.text("Revocar acceso"), role: .destructive) {
                if let id = revokeID { Task { await host.revoke(id) } }
                revokeID = nil
            }
        } message: { Text(L10n.text("Se desconectará. Para volver a entrar necesitará una nueva invitación segura.")) }
    }

    @ViewBuilder private var pairingContent: some View {
        InstructionRow(number: "1", title: L10n.text("Abre AFK en tu iPhone"), detail: L10n.text("Pulsa «Vincular Mac» en la pantalla de inicio."))
        VStack(alignment: .leading, spacing: 16) {
            InstructionRow(number: "2", title: L10n.text("Escanea el QR"), detail: L10n.text("Escanéalo con AFK o copia la invitación y pégala en el iPhone."))
            if let candidate {
                Text(L10n.text("Un iPhone quiere vincularse")).font(.headline)
                Text(candidate.code).font(.system(size: 36, weight: .semibold, design: .monospaced))
                Text(L10n.text("Comprueba que este código aparece en tu iPhone"))
                Button(L10n.text("Los códigos coinciden: vincular")) {
                    approving = true
                    Task {
                        await host.approvePairing(candidate.id)
                        approving = false; completed = host.error == nil
                    }
                }.buttonStyle(.borderedProminent).disabled(approving)
                Button(L10n.text("Rechazar"), role: .destructive) { host.cancelPairing() }
            } else if completed {
                Text(L10n.text("Vinculado. Comparte sesiones desde tu Mac"))
                Button(L10n.text("Sesiones y permisos")) { destination = session == nil ? .devices : .permissions }
            } else if busy {
                HStack(spacing: 12) { ProgressView().controlSize(.small); Text(L10n.text("Preparando invitación segura…")).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 128)
            } else if host.host != nil, let pairing = host.pairing, host.error == nil {
                VStack(alignment: .leading, spacing: 16) {
                    if let qr = pairingQR(pairing.secret) {
                        Image(nsImage: qr).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 360, height: 360).padding(20).background(.white)
                            .accessibilityLabel(L10n.text("Escanea este QR con AFK en tu iPhone"))
                    } else { Text(L10n.text("Usa Pegar invitación en el iPhone.")) }
                    Button(L10n.text(copied ? "Copiado" : "Copiar invitación")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pairing.secret, forType: .string)
                        NSPasteboard.general.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
                        NSPasteboard.general.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
                        copied = true
                        let change = NSPasteboard.general.changeCount
                        Task {
                            try? await Task.sleep(for: .seconds(300))
                            if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
                        }
                    }
                }
                .padding(20).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = remaining(pairing.expiresAt, now: context.date)
                    HStack {
                        Label(seconds > 0 ? L10n.format("Válida durante %@ · un solo uso", String(format: "%d:%02d", seconds / 60, seconds % 60)) : L10n.text("Invitación vencida"), systemImage: "clock")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.text("Generar otra")) { Task { await prepare() } }.disabled(busy)
                    }
                }
            } else {
                Button(L10n.text("Volver a intentar")) { Task { await prepare() } }.buttonStyle(.borderedProminent)
            }
        }
        InstructionRow(number: "3", title: L10n.text("Comparte sesiones desde Dispositivos"), detail: L10n.text("Vincular no da acceso a las terminales. Elige qué compartir y durante cuánto tiempo permitir el control."))
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(L10n.text("Servidor")) { Text(server).textSelection(.enabled).font(.caption.monospaced()) }
            Text(L10n.text("La invitación incluye este servidor. Para un iPhone físico necesitas HTTPS accesible."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("El Mac verifica tu dispositivo. La terminal viaja cifrada de extremo a extremo."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var sessionPermissionsContent: some View {
        Text(L10n.text("Elige qué dispositivos pueden ver o controlar esta sesión."))
            .foregroundStyle(.secondary)
        if busy { ProgressView(L10n.text("Buscando dispositivos…")) }
        else if let session {
            if host.clients.isEmpty {
                Text(L10n.text("Vincula un iPhone para compartir esta sesión."))
                Button(L10n.text("Vincular iPhone")) { destination = .pair }
                    .buttonStyle(.borderedProminent)
            } else {
                ForEach(host.clients) { client in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(client.name, systemImage: "iphone").font(.headline)
                        Text(host.connectedClients.contains(client.id) ? L10n.text("Conectado") : L10n.text("Sin conexión"))
                            .font(.caption).foregroundStyle(.secondary)
                        TrustedDeviceAccess(host: host, client: client.id)
                        if !host.access.isTrusted(client.id) {
                            SessionPermissions(host: host, client: client.id, session: session)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var devicesContent: some View {
        if host.hardwareIdentity {
            Label(L10n.text("Identidad del Mac protegida por Secure Enclave"), systemImage: "lock.shield")
        } else {
            Text(L10n.text("Protege la identidad del Mac antes de autorizar dispositivos de confianza."))
            Button(L10n.text("Proteger identidad del Mac…")) { upgradeIdentity = true }
        }
        if busy { ProgressView(L10n.text("Buscando dispositivos…")) }
        else if host.clients.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "iphone").font(.largeTitle).foregroundStyle(.secondary)
                Text(L10n.text("Tu primer iPhone empieza aquí.")).font(.headline)
                Text(L10n.text("Vincúlalo con una invitación segura para ver y controlar las sesiones de este Mac.")).foregroundStyle(.secondary)
                Button(L10n.text("Vincular iPhone")) { destination = .pair }.buttonStyle(.borderedProminent)
            }.padding(.vertical, 8)
        } else {
            VStack(spacing: 16) {
                ForEach(host.clients) { client in deviceRow(client) }
            }
            Button(L10n.text("Vincular otro iPhone"), systemImage: "plus") { destination = .pair }
                .labelStyle(.titleAndIcon)
        }
        Divider()
        Text(L10n.text("Las sesiones nuevas son privadas salvo para dispositivos de confianza. Sus permisos persisten hasta retirarlos o cortar todo acceso remoto.")).font(.caption).foregroundStyle(.secondary)
        Button(L10n.text("Cortar todo acceso remoto"), role: .destructive) { host.stopRemoteAccess() }
        Button(L10n.text("Revocar todos los dispositivos"), role: .destructive) { revokeAll = true }.disabled(host.clients.isEmpty)
        accessHistory
        AccessToggle(host: host, server: server)
    }

    private func deviceRow(_ client: PairedClient) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "iphone").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(client.name).fontWeight(.medium)
                    Text(host.connectedClients.contains(client.id) ? L10n.text("Conectado") : L10n.text("Sin conexión")).font(.caption).foregroundStyle(.secondary)
                    Text(String(client.id.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("Revocar acceso"), role: .destructive) { revokeID = client.id }
            }
            TrustedDeviceAccess(host: host, client: client.id)
            if !host.access.isTrusted(client.id) { DevicePermissions(host: host, client: client.id) }
        }
    }
    private var accessHistory: some View {
        DisclosureGroup(L10n.text("Historial de accesos")) {
            ForEach(Array(host.accessEvents.suffix(30).reversed())) { event in
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text(event.kind.label)).font(.callout)
                    Text(eventDetails(event)).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
            }
        }
    }
    private func eventDetails(_ event: AccessEvent) -> String {
        var parts = [event.date.formatted(), event.client.map { String($0.prefix(8)) } ?? "Mac"]
        if let session = event.session { parts.append(String(session.prefix(8))) }
        return parts.joined(separator: " · ")
    }

    private var serverContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Servidor de AFK")).font(.headline)
            TextField(L10n.text("URL del servidor"), text: $server).textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.text("URL del servidor de AFK"))
            Text(L10n.text("En este Mac y su simulador puedes usar http://127.0.0.1:8787. Para un iPhone físico usa HTTPS."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(busy ? L10n.text("Conectando…") : L10n.text("Conectar al servidor")) { Task { busy = true; host.error = nil; await host.connect(server: server); busy = false } }
                    .buttonStyle(.borderedProminent).disabled(busy)
                if busy { ProgressView().controlSize(.small) }
            }
            RemoteAccessStatus(host: host, relay: host.relay)
            Divider()
            Text(L10n.text("Versión de pruebas")).font(.headline)
            Text(L10n.text("La terminal viaja cifrada de extremo a extremo. Las sesiones se ejecutan en tu Mac y terminan al salir de AFK."))
                .foregroundStyle(.secondary)
        }
    }

    private func prepare() async {
        guard !busy else { return }
        if destination == .server { return }
        busy = true; copied = false; host.error = nil
        defer { busy = false }
        if destination == .devices || destination == .permissions { await host.refreshClients(server: server); return }
        if destination == .pair {
            completed = false
            await host.beginPairing(server: server)
        }
        else { await host.refreshClients() }
    }

    private func pairingQR(_ value: String) -> NSImage? {
        guard value.utf8.count <= 2048 else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func remaining(_ date: String, now: Date) -> Int {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: date)
        formatter.formatOptions = [.withInternetDateTime]
        return max(0, Int((fractional ?? formatter.date(from: date) ?? now).timeIntervalSince(now)))
    }
}

private struct AccessToggle: View {
    @ObservedObject var host: HostController
    @ObservedObject var relay: SecureHostRelay
    let server: String
    @State private var busy = false
    init(host: HostController, server: String) {
        self.host = host; self.relay = host.relay; self.server = server
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RemoteAccessStatus(host: host, relay: relay)
            Text(L10n.text("Pausar el acceso no cierra tus terminales ni elimina los dispositivos vinculados."))
                .font(.caption).foregroundStyle(.secondary)
            Button(relay.connected ? L10n.text("Pausar acceso remoto") : L10n.text("Reanudar acceso remoto")) {
                if relay.connected { host.pause() }
                else { Task { busy = true; await host.connect(server: server); busy = false } }
            }.disabled(busy)
        }
    }
}

struct LocalTerminalPane: View {
    @ObservedObject var session: HostSession
    let active: Bool
    let actions: () -> AnyView
    private var localControl: Bool { session.lease.owner == "local" }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: !session.running ? "stop.circle" : localControl ? "keyboard" : "eye")
                    .foregroundStyle(localControl ? AFKStyle.accent : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.closing ? L10n.text("Cerrando…") : session.isHidden ? L10n.text("Sesión oculta · vista previa") : !session.running ? L10n.text("Sesión terminada") : localControl ? L10n.text("Estás escribiendo en este Mac") : session.lease.owner.isEmpty ? L10n.text("Estás viendo la sesión") : L10n.text("El iPhone tiene el control"))
                        .font(.callout.weight(.medium))
                    if session.isHidden {
                        Text(L10n.text("Muéstrala en la barra lateral para volver a escribir.")).font(.caption).foregroundStyle(.secondary)
                    } else if session.running && !localControl {
                        Text(L10n.text("Puedes seguir la salida o recuperar el teclado aquí.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                if session.running {
                    Button(localControl ? L10n.text("Pasar a solo lectura") : L10n.text("Escribir aquí")) {
                        if localControl { session.release("local") } else { session.claim("local") }
                    }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .help(L10n.text("Cambiar el control del teclado (⌘⇧L)"))
                    .disabled(!active || session.closing)
                }
                Menu { actions() } label: { Label(L10n.text("Sesión"), systemImage: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            HistoryRecordingStatus(feed: session.feed)
            if let error = session.inputError { InlineNotice(text: error) }
            TerminalCanvas(feed: session.feed, editable: session.running && !session.closing && localControl, input: session.localInput, resize: session.localResize, active: active)
                .id(session.id)
            HStack {
                Label(session.running ? L10n.text("En ejecución en este Mac") : L10n.text("Proceso finalizado"), systemImage: "desktopcomputer")
                Spacer()
                Text(L10n.text("Tamaño del dispositivo que escribe")).help(L10n.text("Recupera el control para ajustar la terminal a esta ventana"))
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
        }

    }
}

private extension AccessEvent.Kind {
    var label: String {
        switch self {
        case .connected: return "Dispositivo conectado"
        case .disconnected: return "Dispositivo desconectado"
        case .shared: return "Permisos de sesión modificados"
        case .creationGranted: return "Creación de sesiones autorizada"
        case .permissionsRemoved: return "Permisos retirados"
        case .viewed: return "Sesión consultada"
        case .controlTaken: return "Control solicitado"
        case .denied: return "Operación rechazada"
        case .expired: return "Permiso vencido"
        case .revoked: return "Dispositivo revocado"
        case .stopped: return "Acceso remoto detenido"
        }
    }
}

private struct AccessDuration: View {
    @Binding var seconds: Double
    var body: some View {
        Picker(L10n.text("Duración"), selection: $seconds) {
            Text(L10n.text("15 minutos")).tag(900.0)
            Text(L10n.text("1 hora")).tag(3600.0)
            Text(L10n.text("8 horas")).tag(28800.0)
        }
    }
}

private struct TrustedDeviceAccess: View {
    @ObservedObject var host: HostController
    let client: String
    @State private var confirming = false
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if host.access.isTrusted(client) {
                Label(L10n.text("Dispositivo de confianza · acceso completo"), systemImage: "checkmark.shield")
                Text(L10n.text("Puede leer, controlar, crear y cerrar todas las sesiones, incluidas las nuevas. Requiere Face ID o Touch ID al conectar."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("Retirar confianza"), role: .destructive) {
                    Task { busy = true; defer { busy = false }; await host.setTrustedAccess(client, enabled: false) }
                }
            } else if host.supportsTrustedAccess(client) {
                Button(L10n.text("Confiar en este dispositivo…"), systemImage: "checkmark.shield") { confirming = true }
            } else {
                Text(L10n.text("Para dar acceso completo, protege la identidad del Mac y vuelve a vincular el iPhone con la app actualizada y Face ID activado."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(busy)
        .confirmationDialog(L10n.text("¿Dar acceso completo a este dispositivo?"), isPresented: $confirming) {
            Button(L10n.text("Confiar y dar acceso completo")) {
                Task { busy = true; defer { busy = false }; await host.setTrustedAccess(client, enabled: true) }
            }
        } message: {
            Text(L10n.text("Podrá leer, controlar, crear y cerrar todas las sesiones, también las futuras y después de reiniciar AFK. Esto permite ejecutar comandos con tu usuario del Mac. Puedes retirar la confianza en cualquier momento."))
        }
    }
}

private struct DevicePermissions: View {
    @ObservedObject var host: HostController
    let client: String
    @State private var duration = 3600.0
    @State private var busy = false
    var body: some View {
        DisclosureGroup(L10n.text("Sesiones y permisos")) {
            VStack(alignment: .leading, spacing: 16) {
                if let last = host.accessEvents.last(where: { $0.client == client && [.connected, .viewed, .controlTaken].contains($0.kind) }) {
                    Text(L10n.text("Último acceso") + " " + last.date.formatted()).font(.caption)
                }
                ForEach(host.sessions) { session in
                    SessionPermissions(host: host, client: client, session: session)
                }
                Divider()
                Text(L10n.text("Crear terminales desde este dispositivo")).font(.headline)
                if let expiry = host.access.createUntil(client: client) {
                    Text(L10n.text("Autorizado hasta") + " " + expiry.formatted()).font(.caption)
                    Button(L10n.text("Retirar permiso")) { host.setCreation(client: client, duration: nil) }
                } else { Text(L10n.text("No autorizado")).font(.caption) }
                AccessDuration(seconds: $duration)
                Text(L10n.text("Las terminales creadas tendrán control hasta ese mismo vencimiento. Cerrar sesiones requiere otro permiso.")).font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("Autorizar creación")) {
                    let requestedDuration = duration, revision = host.accessRevision
                    Task { busy = true; defer { busy = false }
                        do {
                            try await LocalDeviceUnlock().require()
                            guard host.accessRevision == revision else { return }
                            host.setCreation(client: client, duration: requestedDuration)
                        }
                        catch { host.error = error.localizedDescription }
                    }
                }.disabled(busy)
            }.padding(.vertical, 8)
        }
    }
}

private struct SessionPermissions: View {
    @ObservedObject var host: HostController
    let client: String
    let session: HostSession
    @State private var level = SessionAccess.none
    @State private var duration = 3600.0
    @State private var allowClose = false
    @State private var busy = false
    private var current: SessionAccess { host.access.level(client: client, session: session.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.name).font(.headline)
            Text(current == .none ? L10n.text("Privada para este dispositivo") : current == .readOnly ? L10n.text("Solo lectura") : L10n.text("Control autorizado")).font(.caption)
            if let expiry = host.access.controlUntil(client: client, session: session.id) {
                Text(L10n.text("Control autorizado hasta") + " " + expiry.formatted()).font(.caption)
            }
            if host.access.canClose(client: client, session: session.id) { Text(L10n.text("Puede cerrar esta sesión")).font(.caption) }
            Picker(L10n.text("Acceso"), selection: $level) {
                Text(L10n.text("Sin acceso")).tag(SessionAccess.none)
                Text(L10n.text("Solo lectura")).tag(SessionAccess.readOnly)
                Text(L10n.text("Control temporal")).tag(SessionAccess.control)
            }
            if level != .none {
                Toggle(L10n.text("Permitir cerrar esta sesión"), isOn: $allowClose)
                if level == .control || allowClose { AccessDuration(seconds: $duration) }
                Text(L10n.text("El control vuelve a solo lectura tras 5 minutos sin entrada. Leer sigue permitido hasta retirar el acceso o cerrar AFK.")).font(.caption).foregroundStyle(.secondary)
            }
            Button(L10n.text("Aplicar permisos")) {
                let requestedLevel = level, requestedDuration = duration, requestedClose = allowClose, revision = host.accessRevision
                Task { busy = true; defer { busy = false }
                    do {
                        if requestedLevel != .none { try await LocalDeviceUnlock().require() }
                        guard host.accessRevision == revision else { return }
                        host.setAccess(client: client, session: session.id, level: requestedLevel, duration: requestedDuration, allowClose: requestedClose)
                    } catch { host.error = error.localizedDescription }
                }
            }.disabled(busy)
        }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        .onAppear { level = current; allowClose = host.access.canClose(client: client, session: session.id) }
    }
}


struct SessionNameEditor: View {
    @ObservedObject var session: HostSession
    let save: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @FocusState private var focused: Bool

    init(session: HostSession, save: @escaping (String?) -> Void) {
        self.session = session
        self.save = save
        _label = State(initialValue: session.userLabel ?? session.name)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("Renombrar sesión")).font(.title2.weight(.semibold))
            Text(L10n.text("Un nombre estable para reconocer esta tarea. Tiene prioridad sobre el título del programa."))
                .foregroundStyle(.secondary)
            TextField(L10n.text("Nombre de la sesión"), text: $label)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { submit() }
            if let title = session.reportedTitle {
                Text(L10n.text("Título del programa") + ": " + title).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.text("Usar título automático")) { save(nil); dismiss() }
                Spacer()
                Button(L10n.text("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("Guardar")) { submit() }.keyboardShortcut(.defaultAction)
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 480)
            .onAppear { focused = true }
    }
    private func submit() {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        save(value); dismiss()
    }
}

struct SessionGroupEditor: View {
    let group: SessionGroup?
    let save: (String, String, String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbol: String
    @State private var color: String
    @State private var emoji: String
    @FocusState private var emojiFocused: Bool
    @FocusState private var focused: Bool
    private let symbols = [("diamond", "Diamante"), ("square", "Cuadrado"), ("hexagon", "Hexágono"), ("circle", "Círculo"), ("triangle", "Triángulo"), ("folder", "Carpeta"), ("terminal", "Terminal"), ("chevron.left.forwardslash.chevron.right", "Código"), ("server.rack", "Servidor"), ("cloud", "Nube"), ("wrench.and.screwdriver", "Herramientas"), ("star", "Estrella")]
    private let colors = [("blue", "Azul"), ("purple", "Morado"), ("teal", "Verde azulado"), ("orange", "Naranja"), ("pink", "Rosa"), ("gray", "Gris")]

    init(group: SessionGroup?, save: @escaping (String, String, String, String?) -> Void) {
        self.group = group; self.save = save
        _name = State(initialValue: group?.name ?? "")
        _symbol = State(initialValue: group?.symbol ?? "diamond")
        _color = State(initialValue: group?.color ?? "blue")
        _emoji = State(initialValue: group?.emoji ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(group == nil ? L10n.text("Nuevo grupo") : L10n.text("Editar grupo")).font(.title2.weight(.semibold))
            TextField(L10n.text("Nombre del grupo"), text: $name).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { submit() }
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("Símbolo")).font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 10), count: 6), alignment: .leading, spacing: 10) {
                    ForEach(symbols, id: \.0) { item in
                        Button { symbol = item.0; emoji = "" } label: {
                            Image(systemName: item.0).font(.title3).frame(width: 36, height: 32)
                                .foregroundStyle(AFKStyle.groupColor(color))
                                .background(emoji.isEmpty && symbol == item.0 ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(emoji.isEmpty && symbol == item.0 ? Color.primary : .clear))
                        }.buttonStyle(.plain).accessibilityLabel(L10n.text(item.1))
                            .accessibilityAddTraits(emoji.isEmpty && symbol == item.0 ? .isSelected : [])
                    }
                }
            }
            HStack(spacing: 10) {
                TextField(L10n.text("Emoji"), text: $emoji)
                    .textFieldStyle(.roundedBorder).frame(width: 64).focused($emojiFocused)
                    .onChange(of: emoji) { _, value in emoji = String(value.prefix(1)) }
                Button(L10n.text("Elegir emoji…")) {
                    emojiFocused = true
                    DispatchQueue.main.async {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                        NSApp.orderFrontCharacterPalette(nil)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("Color")).font(.headline)
                Picker(L10n.text("Color"), selection: $color) {
                    ForEach(colors, id: \.0) { item in Text(L10n.text(item.1)).tag(item.0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            HStack(spacing: 10) {
                SessionGroupMark(group: SessionGroup(name: name, symbol: symbol, color: color, emoji: emoji))
                Text(name.isEmpty ? L10n.text("Nombre del grupo") : name).fontWeight(.medium).lineLimit(1)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            Text(L10n.text("El nombre y el símbolo identifican el grupo incluso sin distinguir los colores."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.text("Cancelar")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("Guardar")) { submit() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!emoji.isEmpty && SessionGroup.cleanEmoji(emoji) == nil))
            }
        }.padding(24).frame(width: 480).onAppear { focused = true }
    }
    private func submit() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard emoji.isEmpty || SessionGroup.cleanEmoji(emoji) != nil else { return }
        save(value, symbol, color, SessionGroup.cleanEmoji(emoji)); dismiss()
    }
}
