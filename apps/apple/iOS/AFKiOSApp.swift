import SwiftUI
import AFKCore

@main
struct AFKiOSApp: App {
    @StateObject private var model = RemoteModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup { PhoneHome(model: model).task { model.restore() }
            .onChange(of: phase) { _, new in if new == .background { model.suspend() } else if new == .active && model.linked { model.reconnect() } }
        }
    }
}

struct PhoneHome: View {
    @ObservedObject var model: RemoteModel
    @State private var showPair = false
    var body: some View {
        NavigationStack {
            Group {
                if !model.linked {
                    ContentUnavailableView { Label("Llévate tu terminal.", systemImage: "terminal") } description: { Text("Abre AFK en tu Mac y elige Vincular iPhone.") } actions: { Button("Vincular Mac") { showPair = true }.buttonStyle(.borderedProminent) }
                } else {
                    List {
                        Section { Label(model.status, systemImage: "network"); Button("Reconectar") { model.reconnect() } }
                        Section("Sesiones de \(model.hostName)") {
                            ForEach(model.sessions) { s in
                                NavigationLink { PhoneTerminal(model: model, session: s) } label: { Label { VStack(alignment: .leading) { Text(s.name); Text(s.running ? "En ejecución" : "Terminada").font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: "terminal") } }
                            }
                            Button("Nueva sesión", systemImage: "plus") { model.create() }
                        }
                    }
                }
            }.navigationTitle("AFK")
            .toolbar { Button("Vincular", systemImage: "plus") { showPair = true } }
            .sheet(isPresented: $showPair) { PairForm(model: model) }
            .alert("AFK", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("Aceptar") { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
}

struct PairForm: View {
    @ObservedObject var model: RemoteModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("relayURL") private var server = "http://127.0.0.1:8787"
    @State private var code = ""
    @State private var secret = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Servidor de pruebas") { TextField("https://relay.example.com", text: $server).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL) }
                Section("Datos que muestra tu Mac") {
                    TextField("Código del Mac", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    SecureField("Contraseña temporal", text: $secret).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Button { Task { busy = true; await model.pair(server: server, code: code, secret: secret); busy = false; if model.error == nil { dismiss() } } } label: { if busy { ProgressView() } else { Text("Vincular Mac") } }.disabled(busy || code.isEmpty || secret.isEmpty)
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                } footer: { Text("POC: usa un relay de confianza. El servidor puede ver el contenido de la terminal; E2EE pendiente.") }
            }.navigationTitle("Vincular Mac").toolbar { Button("Cancelar") { dismiss() } }
        }
    }
}

struct PhoneTerminal: View {
    @ObservedObject var model: RemoteModel
    let session: SessionInfo
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(!model.ready ? "Sincronizando / sin conexión" : model.canWrite ? "Control: este iPhone" : "Solo lectura", systemImage: "keyboard").font(.caption)
                Spacer()
                Button(model.canWrite ? "Dejar de escribir" : "Tomar control") { if model.canWrite { model.release() } else { model.claim() } }.disabled(!model.ready)
            }.padding(12).background(.bar)
            ScrollView([.horizontal, .vertical]) {
                TerminalSurface(feed: model.feed, editable: model.canWrite, input: model.input).frame(width: 720, height: 460)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if model.canWrite {
                HStack {
                    ForEach([("Esc", "\u{1b}"), ("Tab", "\t"), ("Ctrl+C", "\u{3}"), ("↑", "\u{1b}[A"), ("↓", "\u{1b}[B")], id: \.0) { key in
                        Button(key.0) { model.input(Data(key.1.utf8)) }.frame(minWidth: 44, minHeight: 44)
                    }
                }.buttonStyle(.bordered).padding(8)
            }
            Text("POC · 80 × 24 · desliza para ver las columnas").font(.caption2).foregroundStyle(.secondary).padding(8)
        }.navigationTitle(session.name).navigationBarTitleDisplayMode(.inline)
        .onAppear { model.attach(session.id) }.onDisappear { model.leave() }
        .toolbar { Button("Reconectar", systemImage: "arrow.clockwise") { model.reconnect() } }
    }
}
