import SwiftUI
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
    @StateObject private var host = HostController()
    var body: some Scene {
        WindowGroup("AFK") { MacWorkspace(host: host).onAppear { delegate.host = host } }
            .defaultSize(width: 1040, height: 720)
            .commands { CommandGroup(replacing: .newItem) { Button(L10n.text("Nueva sesión")) { _ = host.create(name: L10n.format("Terminal %lld", host.sessions.count + 1)) }.keyboardShortcut("n") } }
    }
}

private enum WorkspaceSheet: String, Identifiable {
    case pair, devices, server
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pair: return L10n.text("Vincular iPhone")
        case .devices: return L10n.text("Dispositivos")
        case .server: return L10n.text("Conexión")
        }
    }
}

struct MacWorkspace: View {
    @ObservedObject var host: HostController
    @State private var selected: String?
    @AppStorage("relayURL") private var server = Bundle.main.object(forInfoDictionaryKey: "AFKRelayURL") as? String ?? "http://127.0.0.1:8787"
    @State private var sheet: WorkspaceSheet?

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
            if let session = host.sessions.first(where: { $0.id == selected }) {
                LocalTerminalPane(session: session, title: name(for: session))
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
        .sheet(item: $sheet) { destination in
            MacConnectionSheet(host: host, server: $server, destination: destination)
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
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var revokeID: String?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(destination.title).font(.title2.weight(.semibold))
                    Text(destination == .pair ? L10n.text("Tu misma terminal, también en el teléfono.") : destination == .devices ? L10n.text("Decide quién puede acceder a tus sesiones.") : L10n.text("El punto de encuentro entre tu Mac y tu iPhone."))
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
                    else { serverContent }
                    if let error = host.error { InlineNotice(text: error) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: destination == .pair ? 570 : 420)
        }
        .frame(width: 540)
        .task(id: destination) { await prepare() }
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
            InstructionRow(number: "2", title: L10n.text("Comparte esta invitación"), detail: L10n.text("Copia la invitación segura y pégala en el iPhone."))
            if busy {
                HStack(spacing: 12) { ProgressView().controlSize(.small); Text(L10n.text("Preparando invitación segura…")).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 128)
            } else if host.host != nil, let pairing = host.pairing, host.error == nil {
                VStack(alignment: .leading, spacing: 16) {
                    credential(L10n.text("Invitación segura"), value: pairing.secret, large: false)
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
        InstructionRow(number: "3", title: L10n.text("Elige una sesión y toma el control"), detail: L10n.text("Verás la misma salida en ambos dispositivos. Solo uno escribe a la vez."))
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(L10n.text("Servidor")) { Text(server).textSelection(.enabled).font(.caption.monospaced()) }
            Text(L10n.text("La invitación incluye este servidor. Para un iPhone físico necesitas HTTPS accesible."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("El Mac verifica tu dispositivo. La terminal viaja cifrada de extremo a extremo."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func credential(_ title: String, value: String, large: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value.hasPrefix("AFK2:") ? "AFK2:…" : value).font(large ? .system(size: 30, weight: .medium, design: .monospaced) : .system(size: 16, weight: .medium, design: .monospaced))
                    .textSelection(.enabled).accessibilityLabel(title)
            }
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                NSPasteboard.general.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
                NSPasteboard.general.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
                let change = NSPasteboard.general.changeCount
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(300))
                    if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
                }
                copied = title
            } label: {
                Label(copied == title ? L10n.text("Copiado") : L10n.text("Copiar"), systemImage: copied == title ? "checkmark" : "doc.on.doc")
            }.help(L10n.format("Copiar %@", title))
        }
    }

    @ViewBuilder private var devicesContent: some View {
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
                ForEach(host.clients) { client in
                    HStack(spacing: 12) {
                        Image(systemName: "iphone").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(client.name).fontWeight(.medium)
                            Text(L10n.text("Autorizado para acceder a tus sesiones")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.text("Revocar acceso"), role: .destructive) { revokeID = client.id }
                    }
                }
            }
            Button(L10n.text("Vincular otro iPhone"), systemImage: "plus") { destination = .pair }
                .labelStyle(.titleAndIcon)
        }
        Divider()
        AccessToggle(host: host, server: server)
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
        busy = true; copied = nil; host.error = nil
        defer { busy = false }
        if destination == .devices { await host.refreshClients(server: server); return }
        if !host.relay.connected { await host.connect(server: server) }
        guard host.error == nil else { return }
        if destination == .pair {
            do { try await LocalDeviceUnlock().require(); await host.makePairing() }
            catch { host.error = error.localizedDescription }
        }
        else { await host.refreshClients() }
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
    let title: String
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
                }
                Menu {
                    Button(L10n.text("Terminar sesión…"), role: .destructive) { confirmEnd = true }.disabled(!session.running)
                } label: { Label(L10n.text("Sesión"), systemImage: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            TerminalCanvas(feed: session.feed, editable: session.running && localControl, input: session.localInput, resize: session.localResize)
                .id(session.id)
            HStack {
                Label(session.running ? L10n.text("En ejecución en este Mac") : L10n.text("Proceso finalizado"), systemImage: "desktopcomputer")
                Spacer()
                Text(L10n.text("Tamaño del dispositivo que escribe")).help(L10n.text("Recupera el control para ajustar la terminal a esta ventana"))
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .navigationTitle(title)
        .confirmationDialog(L10n.text("¿Terminar esta sesión?"), isPresented: $confirmEnd) {
            Button(L10n.text("Terminar sesión"), role: .destructive) { session.terminate() }
        } message: { Text(L10n.text("Se cerrará la shell para todos los dispositivos. Esta acción no se puede deshacer.")) }
    }
}
