import SwiftUI
import AFKCore

@main
struct AFKiOSApp: App {
    @StateObject private var model = RemoteModel()
    @Environment(\.scenePhase) private var phase
    @State private var needsResume = false
    var body: some Scene {
        WindowGroup {
            PhoneHome(model: model).task { model.restore() }
                .overlay {
                    if phase != .active { Color(.systemBackground).ignoresSafeArea().overlay(Image(systemName: "lock.fill").font(.largeTitle)) }
                }
                .onChange(of: phase) { _, next in
                    if next == .background { needsResume = true; model.suspend() }
                    else if next == .active && needsResume { needsResume = false; if model.linked { model.reconnect() } }
                }
        }
    }
}

struct PhoneHome: View {
    @ObservedObject var model: RemoteModel
    @State private var showPair = false
    private func title(_ session: SessionInfo) -> String {
        guard session.name == "Shell", let index = model.sessions.firstIndex(where: { $0.id == session.id }) else { return session.name }
        return L10n.format("Terminal %lld", index + 1)
    }
    var body: some View {
        NavigationStack {
            Group {
                if !model.linked {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            Image(systemName: "terminal").font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 12) {
                                Text(L10n.text("Tu Mac se queda.\nTu terminal va contigo.")).font(.largeTitle.weight(.semibold))
                                Text(L10n.text("Mira lo que está pasando y continúa desde aquí, en la misma sesión."))
                                    .font(.body).foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 20) {
                                InstructionRow(number: "1", title: L10n.text("Abre AFK en tu Mac"), detail: L10n.text("Elige «Vincular iPhone»."))
                                InstructionRow(number: "2", title: L10n.text("Pega la invitación segura"), detail: L10n.text("Copia la invitación que aparece en tu Mac."))
                            }
                            Button { showPair = true } label: {
                                Text(L10n.text("Vincular mi Mac")).fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.borderedProminent)
                        }.padding(24).frame(maxWidth: 540, alignment: .leading).frame(maxWidth: .infinity)
                    }
                } else {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(model.hostName, systemImage: "desktopcomputer").font(.headline)
                                ConnectionIndicator(title: model.hostAvailable ? L10n.text("Mac disponible") : L10n.text("Mac sin conexión"), connected: model.hostAvailable)
                                if !model.hostAvailable {
                                    Text(L10n.text("Mantén AFK abierto en tu Mac para acceder a sus sesiones."))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    Button(L10n.text("Volver a conectar"), systemImage: "arrow.clockwise") { model.reconnect() }
                                        .frame(minHeight: 44)
                                }
                            }.padding(.vertical, 8)
                        }
                        Section {
                            if model.sessions.isEmpty {
                                Text(model.hostAvailable ? L10n.text("Abre tu primera terminal aquí o en el Mac.") : L10n.text("Las sesiones aparecerán cuando tu Mac se conecte."))
                                    .foregroundStyle(.secondary).padding(.vertical, 8)
                            }
                            ForEach(model.sessions) { session in
                                NavigationLink {
                                    PhoneTerminal(model: model, session: session, title: title(session))
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "terminal").font(.title2).foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(title(session)).font(.body.weight(.medium))
                                            Text(session.running ? L10n.text("En ejecución · toca para abrir") : L10n.text("Sesión terminada"))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.frame(minHeight: 48)
                                }.disabled(!model.hostAvailable)
                            }
                            Button { model.create() } label: {
                                Label(L10n.text("Nueva sesión"), systemImage: "plus").frame(minHeight: 44)
                            }.disabled(!model.hostAvailable)
                        } header: { Text(L10n.text("Tus sesiones")) }
                        footer: { Text(L10n.text("Las sesiones se ejecutan en tu Mac. Salir de AFK en el Mac las detiene.")) }
                    }
                }
            }
            .navigationTitle("AFK")
            .toolbar {
                if model.linked {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(L10n.text("Reconectar"), systemImage: "arrow.clockwise") { model.reconnect() }
                            Button(L10n.text("Vincular otro Mac…"), systemImage: "plus") { showPair = true }
                        } label: { Label(L10n.text("Opciones"), systemImage: "ellipsis.circle") }
                        .accessibilityLabel(L10n.text("Opciones de conexión"))
                    }
                }
            }
            .sheet(isPresented: $showPair) { PairForm(model: model) }
            .alert(L10n.text("No se pudo completar la acción"), isPresented: Binding(
                get: { model.error != nil && !showPair },
                set: { if !$0 { model.error = nil } }
            )) { Button(L10n.text("Aceptar")) { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
}

struct PairForm: View {
    @ObservedObject var model: RemoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var invitation = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(L10n.text("En tu Mac, abre AFK y pulsa «Vincular iPhone»."), systemImage: "desktopcomputer")
                    Text(L10n.text("Copia la invitación segura del Mac y pégala aquí. Incluye la identidad del Mac y el servidor."))
                    if model.linked { Text(L10n.text("Este vínculo reemplazará en el iPhone al Mac que tienes guardado.")) }
                }
                Section {
                    SecureField(L10n.text("Invitación segura"), text: $invitation)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: { Text(L10n.text("La invitación dura cinco minutos y solo se puede usar una vez.")) }
                Section {
                    Button {
                        Task {
                            busy = true; model.error = nil
                            await model.pair(invitation: invitation)
                            busy = false
                            if model.error == nil { invitation = ""; dismiss() }
                        }
                    } label: {
                        HStack { if busy { ProgressView() }; Text(L10n.text("Vincular Mac")) }
                    }.disabled(busy || invitation.isEmpty)
                    if let error = model.error { InlineNotice(text: error) }
                } footer: { Text(L10n.text("El Mac verifica tu dispositivo. La terminal viaja cifrada de extremo a extremo.")) }
            }
            .navigationTitle(L10n.text("Vincular Mac"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancelar")) { dismiss() } } }
            .onAppear { model.error = nil }
            .interactiveDismissDisabled(busy)
        }
    }
}

struct PhoneTerminal: View {
    @ObservedObject var model: RemoteModel
    let session: SessionInfo
    let title: String
    private var running: Bool { model.sessions.first(where: { $0.id == session.id })?.running ?? session.running }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Label(!running ? L10n.text("Sesión terminada") : !model.hostAvailable ? L10n.text("Esperando al Mac") : !model.ready ? (model.sessionNotice == nil ? L10n.text("Recuperando la sesión…") : L10n.text("No se pudo abrir la sesión")) : model.canWrite ? L10n.text("Estás escribiendo desde el iPhone") : L10n.text("Estás viendo la sesión"), systemImage: model.canWrite ? "keyboard" : "eye")
                    .font(.subheadline.weight(.medium))
                if let notice = model.sessionNotice, running { InlineNotice(text: notice) }
                if running && model.ready {
                    Button(model.canWrite ? L10n.text("Pasar a solo lectura") : L10n.text("Escribir desde aquí")) {
                        if model.canWrite { model.release() } else { model.claim() }
                    }.buttonStyle(.bordered).frame(minHeight: 44)
                } else if running {
                    Button(L10n.text("Volver a conectar"), systemImage: "arrow.clockwise") { model.reconnect() }
                        .frame(minHeight: 44)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            TerminalCanvas(feed: model.feed, editable: model.canWrite && running, input: model.input, resize: model.resize)
            if model.canWrite && running {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach([("Esc", "\u{1b}"), ("Tab", "\t"), ("Ctrl+C", "\u{3}"), ("↑", "\u{1b}[A"), ("↓", "\u{1b}[B"), ("←", "\u{1b}[D"), ("→", "\u{1b}[C")], id: \.0) { key in
                            Button(key.0) { model.input(Data(key.1.utf8)) }
                                .font(.subheadline.monospaced()).frame(minWidth: 44, minHeight: 44)
                                .accessibilityLabel(keyLabel(key.0))
                        }
                    }.padding(.horizontal, 12)
                }.scrollIndicators(.hidden).buttonStyle(.bordered).padding(.vertical, 4)
            } else {
                Text(L10n.text("Desliza la terminal para ver las demás columnas."))
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .onAppear { model.attach(session.id) }.onDisappear { model.leave() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(L10n.text("Reconectar"), systemImage: "arrow.clockwise") { model.reconnect() }
                } label: { Label(L10n.text("Opciones de sesión"), systemImage: "ellipsis.circle") }
            }
        }
    }
    private func keyLabel(_ key: String) -> String {
        switch key {
        case "↑": return L10n.text("Flecha arriba")
        case "↓": return L10n.text("Flecha abajo")
        case "←": return L10n.text("Flecha izquierda")
        case "→": return L10n.text("Flecha derecha")
        case "Ctrl+C": return L10n.text("Control C, interrumpir comando")
        default: return key
        }
    }
}
