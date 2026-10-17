import SwiftUI
import CoreImage.CIFilterBuiltins
import AFKCore
import AFKHost

final class AppDelegate: NSObject, NSApplicationDelegate {
    var host: HostController?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard host?.sessions.contains(where: \.running) == true else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = L10n.text("¿Detener AFK y sus sesiones?"); alert.informativeText = L10n.text("Se cerrarán los procesos de estas sesiones. Cerrar solo la ventana los mantiene activos.")
        alert.addButton(withTitle: L10n.text("Detener AFK")); alert.addButton(withTitle: L10n.text("Cancelar"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        host?.shutdown(); return .terminateNow
    }
}

@main
struct AFKMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var host = HostController(historyDirectory: TerminalHistory.defaultDirectory)
    var body: some Scene {
        WindowGroup("AFK") { MacWorkspace(host: host).onAppear { delegate.host = host } }
            .defaultSize(width: 1040, height: 720)
            .commands { CommandGroup(replacing: .newItem) { Button(L10n.text("Nueva sesión")) { _ = host.create(name: L10n.format("Terminal %lld", host.sessions.count + 1)) }.keyboardShortcut("n") } }
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
    @State private var selected: String?
    @AppStorage("relayURL") private var server = Bundle.main.object(forInfoDictionaryKey: "AFKRelayURL") as? String ?? "http://127.0.0.1:8787"
    @State private var sheet: WorkspaceSheet?
    @State private var showingHistory = false
    @State private var permissionSession: HostSession?

    private func createSession() {
        selected = host.create(name: L10n.format("Terminal %lld", host.sessions.count + 1))?.id
    }
    private func name(for session: HostSession) -> String {
        guard session.name == "Shell", let index = host.sessions.firstIndex(where: { $0.id == session.id }) else { return session.name }
        return L10n.format("Terminal %lld", index + 1)
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Section(L10n.text("Sesiones")) {
                    ForEach(host.sessions) { session in
                        MacSessionRow(session: session, title: name(for: session)).tag(session.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .top) {
                HStack {
                    Text("AFK").font(.title2.weight(.semibold))
                    Spacer()
                    Button(action: createSession) { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help(L10n.text("Nueva sesión (⌘N)"))
                        .accessibilityLabel(L10n.text("Nueva sesión"))
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    Button { showingHistory = true } label: { Label(L10n.text("Historial guardado"), systemImage: "clock") }
                    Button(action: createSession) { Label(L10n.text("Nueva sesión"), systemImage: "plus") }
                    Button { sheet = .devices } label: { Label(L10n.text("Dispositivos"), systemImage: "iphone") }
                    Button { sheet = .server } label: { Label(L10n.text("Conexión"), systemImage: "network") }
                    RemoteAccessStatus(host: host, relay: host.relay)
                        .padding(.top, 4)
                }
                .buttonStyle(.plain).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            if !host.sessions.isEmpty {
                ZStack {
                    ForEach(host.sessions) { session in
                        LocalTerminalPane(session: session, active: session.id == selected, managePermissions: {
                            permissionSession = session
                            sheet = .permissions
                        })
                        .opacity(session.id == selected ? 1 : 0)
                        .allowsHitTesting(session.id == selected)
                        .accessibilityHidden(session.id != selected)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label(L10n.text("Tu terminal, contigo."), systemImage: "terminal")
                } description: {
                    Text(L10n.text("Abre una sesión en este Mac y continúa desde tu iPhone."))
                } actions: {
                    Button(L10n.text("Nueva sesión"), action: createSession).buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(host.sessions.first(where: { $0.id == selected }).map { name(for: $0) } ?? "AFK")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { sheet = .pair } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus")
                        Text(L10n.text("Vincular iPhone"))
                    }.fixedSize()
                }
                .buttonStyle(.borderedProminent)
                .help(L10n.text("Mostrar la invitación segura para vincular un iPhone"))
                .accessibilityIdentifier("pair-iphone")
            }
        }
        .sheet(isPresented: $showingHistory) {
            SavedTerminalHistory(active: Set(host.sessions.filter(\.running).compactMap { $0.feed.history?.entry.id }))
        }
        .sheet(item: $sheet) { destination in
            MacConnectionSheet(host: host, server: $server, destination: destination,
                               session: destination == .permissions ? permissionSession : nil)
        }
        .alert(L10n.text("No se pudo completar la acción"), isPresented: Binding(
            get: { host.error != nil && sheet == nil },
            set: { if !$0 { host.error = nil } }
        )) { Button(L10n.text("Aceptar")) { host.error = nil } } message: { Text(host.error ?? "") }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            if host.sessions.isEmpty { createSession() }
            else if selected == nil { selected = host.sessions.first?.id }
        }
        .task { await host.restoreConnection(server: server) }
        .onChange(of: host.sessions.count) { _, _ in selected = host.sessions.last?.id }
    }
}

private struct MacSessionRow: View {
    @ObservedObject var session: HostSession
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "terminal").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(!session.running ? L10n.text("Terminada") : session.lease.owner == "local" ? L10n.text("Escribiendo en este Mac") : session.lease.owner.isEmpty ? L10n.text("Solo lectura") : L10n.text("Control desde iPhone"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
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
    let managePermissions: () -> Void
    @State private var confirmEnd = false
    private var localControl: Bool { session.lease.owner == "local" }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: !session.running ? "stop.circle" : localControl ? "keyboard" : "eye")
                    .foregroundStyle(localControl ? AFKStyle.accent : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(!session.running ? L10n.text("Sesión terminada") : localControl ? L10n.text("Estás escribiendo en este Mac") : session.lease.owner.isEmpty ? L10n.text("Estás viendo la sesión") : L10n.text("El iPhone tiene el control"))
                        .font(.callout.weight(.medium))
                    if session.running && !localControl {
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
                    .disabled(!active)
                }
                Menu {
                    Button(action: managePermissions) {
                        Label(L10n.text("Permisos de la sesión…"), systemImage: "person.badge.key")
                    }
                    .accessibilityIdentifier("session-permissions")
                    Divider()
                    Button(L10n.text("Terminar sesión…"), role: .destructive) { confirmEnd = true }.disabled(!session.running)
                } label: { Label(L10n.text("Sesión"), systemImage: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            HistoryRecordingStatus(feed: session.feed)
            TerminalCanvas(feed: session.feed, editable: session.running && localControl, input: session.localInput, resize: session.localResize, active: active)
                .id(session.id)
            HStack {
                Label(session.running ? L10n.text("En ejecución en este Mac") : L10n.text("Proceso finalizado"), systemImage: "desktopcomputer")
                Spacer()
                Text(L10n.text("Tamaño del dispositivo que escribe")).help(L10n.text("Recupera el control para ajustar la terminal a esta ventana"))
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
        }

        .confirmationDialog(L10n.text("¿Terminar esta sesión?"), isPresented: $confirmEnd) {
            Button(L10n.text("Terminar sesión"), role: .destructive) { session.terminate() }
        } message: { Text(L10n.text("Se cerrará la shell para todos los dispositivos. Esta acción no se puede deshacer.")) }
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
