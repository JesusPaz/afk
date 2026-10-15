import SwiftUI
import AFKCore
import AFKHost

final class AppDelegate: NSObject, NSApplicationDelegate {
    var host: HostController?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard host?.sessions.contains(where: \.running) == true else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "¿Detener AFK y sus sesiones?"; alert.informativeText = "Se cerrarán los procesos de estas sesiones. Cerrar solo la ventana los mantiene activos."
        alert.addButton(withTitle: "Detener AFK"); alert.addButton(withTitle: "Cancelar")
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
            .commands { CommandGroup(replacing: .newItem) { Button("Nueva sesión") { _ = host.create() }.keyboardShortcut("n") } }
    }
}

struct MacWorkspace: View {
    @ObservedObject var host: HostController
    @State private var selected: String?
    @AppStorage("relayURL") private var server = "http://127.0.0.1:8787"
    @State private var sheet: String?
    @State private var busy = false
    @State private var revokeID: String?
    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Section("Sesiones") { ForEach(host.sessions) { s in
                    Label { VStack(alignment: .leading, spacing: 3) { Text(s.name); Text(s.running ? "Shell local" : "Terminada").font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: "terminal") }.tag(s.id)
                } }
            }
            .navigationTitle("AFK")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Nueva sesión", systemImage: "plus") { selected = host.create()?.id }
                    Button("Dispositivos", systemImage: "iphone") { sheet = "devices"; Task { await host.refreshClients() } }
                    Button("Conexión", systemImage: "network") { sheet = "server" }
                    Text(host.connectionStatus).font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.plain).padding()
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            if let session = host.sessions.first(where: { $0.id == selected }) {
                LocalTerminalPane(session: session)
            } else {
                ContentUnavailableView { Label("Tu terminal, contigo.", systemImage: "terminal") } description: { Text("Abre una sesión aquí y continúa desde tu iPhone.") } actions: { Button("Abrir terminal") { selected = host.create()?.id }.buttonStyle(.borderedProminent) }
            }
        }
        .toolbar { Button("Vincular iPhone", systemImage: "iphone.and.arrow.forward") {
            sheet = "pair"; Task { busy = true; await host.connect(server: server); await host.makePairing(); busy = false }
        } }
        .sheet(isPresented: Binding(get: { sheet != nil }, set: { if !$0 { sheet = nil } })) { settingsSheet.frame(width: 460).padding(24) }
        .alert("AFK", isPresented: Binding(get: { host.error != nil }, set: { if !$0 { host.error = nil } })) { Button("Aceptar") { host.error = nil } } message: { Text(host.error ?? "") }
        .confirmationDialog("¿Revocar este iPhone?", isPresented: Binding(get: { revokeID != nil }, set: { if !$0 { revokeID = nil } })) {
            Button("Revocar acceso", role: .destructive) { if let id = revokeID { Task { await host.revoke(id) } }; revokeID = nil }
        } message: { Text("Se desconectará y tendrá que vincularse otra vez para acceder.") }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { if host.sessions.isEmpty { selected = host.create()?.id } }
    }
    @ViewBuilder private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(sheet == "pair" ? "Vincular iPhone" : sheet == "devices" ? "Dispositivos" : "Conexión").font(.title2.bold()); Spacer(); Button("Cerrar") { sheet = nil } }
            if sheet == "pair" {
                Text("Abre AFK en tu iPhone e introduce estos datos.").foregroundStyle(.secondary)
                if busy { ProgressView("Preparando vínculo…") }
                if let h = host.host, let pairing = host.pairing {
                    LabeledContent("Código del Mac") { Text(h.code).font(.title.monospaced()).textSelection(.enabled) }
                    LabeledContent("Contraseña temporal") { Text(pairing.secret).font(.body.monospaced()).textSelection(.enabled) }
                    Text("Vence en 5 minutos · un solo uso").font(.caption).foregroundStyle(.secondary)
                    Text("Vincular autoriza al iPhone a ver y controlar tus sesiones de AFK.")
                }
                Text("POC: relay de confianza. No hay cifrado de extremo a extremo todavía.").font(.caption).foregroundStyle(.secondary)
            } else if sheet == "devices" {
                if host.clients.isEmpty { Text("No hay iPhones vinculados.").foregroundStyle(.secondary) }
                ForEach(host.clients) { c in HStack { Label(c.name, systemImage: "iphone"); Spacer(); Button("Revocar", role: .destructive) { revokeID = c.id } } }
                Button("Pausar acceso remoto") { host.pause() }
                Button("Reanudar acceso remoto") { Task { await host.connect(server: server) } }
            } else {
                TextField("URL del relay", text: $server).textFieldStyle(.roundedBorder)
                Text("Para el simulador: http://127.0.0.1:8787. En un iPhone físico usa un relay HTTPS de confianza.").font(.caption).foregroundStyle(.secondary)
                Button("Conectar") { Task { await host.connect(server: server) } }.buttonStyle(.borderedProminent)
            }
        }
    }
}

struct LocalTerminalPane: View {
    @ObservedObject var session: HostSession
    @State private var confirmEnd = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(session.lease.owner == "local" ? "Control: este Mac" : session.lease.owner.isEmpty ? "Solo lectura" : "Control: iPhone", systemImage: "keyboard")
                Spacer()
                Button(session.lease.owner == "local" ? "Dejar de escribir" : "Recuperar control") {
                    if session.lease.owner == "local" { session.release("local") } else { session.claim("local") }
                }.keyboardShortcut("l", modifiers: [.command, .shift]).disabled(!session.running)
            }.padding(12).background(.bar)
            ScrollView([.horizontal, .vertical]) {
                TerminalSurface(feed: session.feed, editable: session.running && session.lease.owner == "local", input: session.localInput)
                    .frame(width: 720, height: 460).id(session.id)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Text(session.running ? "POC · 80 × 24 · historial acotado" : "Sesión terminada").foregroundStyle(.secondary)
                Spacer(); Button("Terminar sesión", role: .destructive) { confirmEnd = true }.disabled(!session.running)
            }.font(.caption).padding(12)
        }.navigationTitle(session.name)
        .confirmationDialog("¿Terminar la sesión?", isPresented: $confirmEnd) { Button("Terminar sesión", role: .destructive) { session.terminate() } } message: { Text("Se cerrarán los procesos de esta sesión para todos los dispositivos.") }
    }
}
