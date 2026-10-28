import SwiftUI
import AVFoundation
import VisionKit
import Speech
import AFKCore

@main
struct AFKiOSApp: App {
    @StateObject private var model = RemoteModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            PhoneHome(model: model).task { model.restore() }
                .overlay {
                    if phase != .active { Color(.systemBackground).ignoresSafeArea().overlay(Image(systemName: "lock.fill").font(.largeTitle)) }
                }
                .onChange(of: phase) { _, next in
                    if next == .background { model.suspend() }
                    else if next == .active { model.activate() }
                }
        }
    }
}

struct PhoneHome: View {
    @ObservedObject var model: RemoteModel
    @State private var showPair = false
    @State private var closeTarget: SessionInfo?
    @State private var collapsedGroupIDs: Set<String> = []
    private var activeSessions: [SessionInfo] { model.visibleSessions.filter(\.running) }
    private var groups: [SessionGroup] {
        var seen: Set<String> = []
        return activeSessions.compactMap(\.group).filter { seen.insert($0.id).inserted }
    }
    private func title(_ session: SessionInfo) -> String { session.name }
    @ViewBuilder private func sessionRow(_ session: SessionInfo, hidden: Bool = false) -> some View {
        Group {
            if hidden {
                HStack {
                    sessionLabel(session, showGroup: true)
                    Spacer()
                    Button(L10n.text("Mostrar")) { model.showSession(session.id) }.buttonStyle(.bordered)
                }
            } else {
                NavigationLink {
                    PhoneTerminal(model: model, session: session, title: title(session))
                } label: { sessionLabel(session, showGroup: !session.running) }
                .disabled(!model.hostAvailable || session.closing == true)
            }
        }
        .contextMenu {
            if hidden { Button(L10n.text("Mostrar"), systemImage: "eye") { model.showSession(session.id) } }
            else { Button(L10n.text("Ocultar en este dispositivo"), systemImage: "eye.slash") { model.hideSession(session.id) } }
            Button(model.closeActionTitle(session), role: .destructive) {
                if session.running { closeTarget = session } else { model.closeSession(session.id) }
            }.disabled(!model.canCloseSession(session))
        }
    }
    private func sessionLabel(_ session: SessionInfo, showGroup: Bool) -> some View {
        HStack(spacing: 12) {
            SessionGroupMark(group: session.group)
            VStack(alignment: .leading, spacing: 5) {
                Text(title(session)).font(.body.weight(.medium)).lineLimit(2)
                if let context = session.context, !context.isEmpty { Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if showGroup, let group = session.group { Text(group.name).font(.caption).foregroundStyle(.secondary) }
                if model.sessions.filter({ $0.name == session.name && $0.context == session.context }).count > 1 {
                    Text(String(session.id.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text(L10n.text(session.closing == true ? "Cerrando…" : session.running ? "En ejecución · toca para abrir" : "Sesión terminada"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(minHeight: 48)
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
                                InstructionRow(number: "2", title: L10n.text("Escanea el QR"), detail: L10n.text("Escanea el QR que aparece en tu Mac."))
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
                        if let id = model.lastHiddenSessionID, let hidden = model.hiddenSessions.first(where: { $0.id == id }) {
                            Section {
                                Text(L10n.format("Ocultaste %@ en este dispositivo", hidden.name)).font(.subheadline)
                                Button(L10n.text("Deshacer")) { model.showSession(id) }
                            }
                        }
                        if model.sessions.isEmpty || activeSessions.contains(where: { $0.group == nil }) {
                            Section {
                                if model.sessions.isEmpty {
                                    Text(model.hostAvailable ? L10n.text("Comparte una sesión desde Dispositivos en tu Mac.") : L10n.text("Las sesiones aparecerán cuando tu Mac se conecte."))
                                        .foregroundStyle(.secondary).padding(.vertical, 8)
                                }
                                ForEach(activeSessions.filter { $0.group == nil }) { session in sessionRow(session) }
                            } header: { Text(L10n.text(groups.isEmpty ? "Tus sesiones" : "Sin grupo")) }
                        }
                        ForEach(groups) { group in
                            Section {
                                DisclosureGroup(isExpanded: Binding(
                                    get: { !collapsedGroupIDs.contains(group.id) },
                                    set: { if $0 { collapsedGroupIDs.remove(group.id) } else { collapsedGroupIDs.insert(group.id) } }
                                )) {
                                    ForEach(activeSessions.filter { $0.group?.id == group.id }) { session in sessionRow(session) }
                                } label: {
                                    HStack {
                                        Label { Text(group.name) } icon: { SessionGroupMark(group: group) }.foregroundStyle(AFKStyle.groupColor(group.color))
                                        Spacer()
                                        Text(String(activeSessions.filter { $0.group?.id == group.id }.count)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if model.visibleSessions.contains(where: { !$0.running }) {
                            Section(L10n.text("Terminadas")) {
                                ForEach(model.visibleSessions.filter { !$0.running }) { session in sessionRow(session) }
                            }
                        }
                        if !model.hiddenSessions.isEmpty {
                            Section {
                                DisclosureGroup(L10n.format("Ocultas (%lld)", model.hiddenSessions.count)) {
                                    ForEach(model.hiddenSessions) { session in sessionRow(session, hidden: true) }
                                }
                            } footer: { Text(L10n.text("Ocultar no detiene la terminal. Los grupos se organizan en el Mac.")) }
                        }
                    }
                }
            }
            .navigationTitle("AFK")
            .toolbar {
                if model.linked {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.text("Nueva sesión"), systemImage: "plus") { model.create() }
                            .disabled(!model.hostAvailable || !model.canCreate)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(L10n.text("Reconectar"), systemImage: "arrow.clockwise") { model.reconnect() }
                            Button(L10n.text("Vincular otro Mac…"), systemImage: "plus") { showPair = true }
                        } label: { Label(L10n.text("Opciones"), systemImage: "ellipsis.circle") }
                        .accessibilityLabel(L10n.text("Opciones de conexión"))
                    }
                }
            }
            .confirmationDialog(L10n.text(closeTarget?.canRemove == true ? "¿Cerrar y quitar esta sesión?" : "¿Terminar esta sesión?"), isPresented: Binding(get: { closeTarget != nil }, set: { if !$0 { closeTarget = nil } }), titleVisibility: .visible) {
                Button(L10n.text(closeTarget?.canRemove == true ? "Cerrar y quitar" : "Terminar sesión"), role: .destructive) {
                    if let target = closeTarget { model.closeSession(target.id) }; closeTarget = nil
                }
            } message: {
                Text([closeTarget?.group?.name, closeTarget?.name].compactMap { $0 }.joined(separator: " / ") + "\n" + L10n.text("Se detendrá la terminal. Su historial guardado se conservará."))
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
    @Environment(\.scenePhase) private var phase
    @State private var invitation = ""
    @State private var busy = false
    @State private var scanning = false
    @State private var origin: String?
    @State private var confirmOrigin = false
    @State private var completed = false
    var body: some View {
        NavigationStack {
            Form {
                if completed {
                    Text(L10n.text("Vinculado. Comparte sesiones desde tu Mac"))
                } else if busy {
                    if let code = model.comparisonCode {
                        Text(code).font(.system(size: 36, weight: .semibold, design: .monospaced))
                        Text(L10n.text("Confirma en tu Mac"))
                    } else { ProgressView(L10n.text("Conectando…")) }
                } else {
                    Section {
                        Label(L10n.text("En tu Mac, abre AFK y pulsa «Vincular iPhone»."), systemImage: "desktopcomputer")
                        if model.linked { Text(L10n.text("Este vínculo reemplazará en el iPhone al Mac que tienes guardado.")) }
                        Button(L10n.text("Escanear QR"), systemImage: "qrcode.viewfinder") {
                            Task {
                                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                                guard phase == .active else { return }
                                if allowed && DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                                    invitation = ""; origin = nil; scanning = true
                                }
                                else { model.error = L10n.text("Cámara no disponible. Puedes pegar la invitación o habilitar la cámara en Ajustes.") }
                            }
                        }
                    }
                    Section(L10n.text("Pegar invitación")) {
                        SecureField(L10n.text("Invitación segura"), text: $invitation)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button(L10n.text("Continuar")) { validate() }.disabled(invitation.isEmpty)
                    }
                }
                if let error = model.error { InlineNotice(text: error) }
            }
            .navigationTitle(L10n.text("Vincular Mac"))
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(L10n.text(completed ? "Cerrar" : "Cancelar")) { model.cancelPairing(); invitation = ""; dismiss() }
            } }
            .onAppear { model.error = nil }
            .onDisappear { model.cancelPairing(); invitation = "" }
            .onChange(of: phase) { _, next in
                if next == .background { scanning = false; invitation = ""; origin = nil; confirmOrigin = false; model.cancelPairing() }
            }
            .interactiveDismissDisabled(busy)
            .sheet(isPresented: $scanning, onDismiss: { if !invitation.isEmpty { validate() } }) {
                NavigationStack {
                    PairingScanner(accept: { value in scanning = false; invitation = value }, unavailable: {
                        scanning = false
                        model.error = L10n.text("Cámara no disponible. Puedes pegar la invitación o habilitar la cámara en Ajustes.")
                    })
                        .navigationTitle(L10n.text("Escanear QR"))
                        .toolbar { Button(L10n.text("Cancelar")) { scanning = false } }
                }
            }
            .confirmationDialog(L10n.text("Conectar con este servidor"), isPresented: $confirmOrigin, titleVisibility: .visible) {
                Button(L10n.text("Continuar")) {
                    guard !busy else { return }
                    busy = true; model.error = nil
                    let value = invitation; invitation = ""
                    Task { await model.pair(invitation: value); busy = false; completed = model.error == nil }
                }
                Button(L10n.text("Cancelar"), role: .cancel) { invitation = ""; origin = nil }
            } message: { Text(origin ?? "") }
        }
    }
    private func validate() {
        do { origin = try SecureInvitation.decode(invitation).server; confirmOrigin = true }
        catch { model.error = error.localizedDescription; invitation = "" }
    }
}

struct PhoneTerminal: View {
    @ObservedObject var model: RemoteModel
    let session: SessionInfo
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEnd = false
    @State private var draft = ""
    @State private var mirroredDraft = ""
    @State private var dictationPrefix = ""
    @StateObject private var dictation = PhoneDictation()
    @FocusState private var typing: Bool
    @State private var composing = false
    private var currentSession: SessionInfo { model.sessions.first(where: { $0.id == session.id }) ?? session }
    private var terminalTitle: String {
        let duplicate = model.sessions.filter { $0.name == currentSession.name && $0.context == currentSession.context }.count > 1
        return currentSession.name + (duplicate ? " · " + String(session.id.prefix(8)) : "")
    }
    private var running: Bool { model.sessions.first(where: { $0.id == session.id })?.running ?? false }
    private var writing: Bool { model.canWrite && running }
    /// While typing or dictating, only the terminal and the input bar stay on screen.
    private var immersive: Bool { writing && (typing || dictation.listening) }
    var body: some View {
        VStack(spacing: 0) {
            TerminalCanvas(feed: model.feed, editable: writing, input: { releaseDraft(); model.input($0) }, resize: model.resize,
                           keyboardRequested: openKeyboard)
                .overlay(alignment: .top) { notices }
            if writing { inputBar } else { statusBar }
        }
        .toolbarBackground(AFKStyle.terminalBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar(immersive ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(immersive)
        .animation(.easeOut(duration: 0.2), value: immersive)
        .onChange(of: typing) { _, focused in if !focused { composing = false } }
        .onChange(of: running) { _, _ in releaseDraft() }
        .onChange(of: writing) { _, next in if !next { releaseDraft(); typing = false } }
        .confirmationDialog(L10n.text(currentSession.canRemove == true ? "¿Cerrar y quitar esta sesión?" : "¿Terminar esta sesión?"), isPresented: $confirmEnd, titleVisibility: .visible) {
            Button(L10n.text(currentSession.canRemove == true ? "Cerrar y quitar" : "Terminar sesión"), role: .destructive) { model.closeSession(session.id) }
        } message: { Text([currentSession.group?.name, currentSession.name].compactMap { $0 }.joined(separator: " / ") + "\n" + L10n.text("Se detendrá la terminal. Su historial guardado se conservará.")) }
        .navigationTitle(terminalTitle).navigationBarTitleDisplayMode(.inline)
        .onAppear { model.attach(session.id) }.onDisappear { dictation.cancel(); model.leave() }
        .onChange(of: model.selected) { _, selection in if selection == nil { dismiss() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    let place = [currentSession.group?.name, currentSession.context].compactMap { $0 }
                    if !place.isEmpty { Text(place.joined(separator: " · ")) }
                    if writing {
                        if let expiry = model.selectedInfo?.controlExpiresAt {
                            Text(L10n.text("Control autorizado hasta") + " " + expiry.formatted(date: .omitted, time: .shortened))
                        }
                        Button(L10n.text("Pasar a solo lectura"), systemImage: "eye") { model.release() }
                    }
                    Button(L10n.text("Reconectar"), systemImage: "arrow.clockwise") { model.reconnect() }
                    Button(L10n.text("Ocultar en este dispositivo"), systemImage: "eye.slash") { model.hideSession(session.id); dismiss() }
                    Button(model.closeActionTitle(currentSession), role: .destructive) {
                        if running { confirmEnd = true } else { model.closeSession(session.id) }
                    }.disabled(!model.canTerminate)
                } label: { Label(L10n.text("Opciones de sesión"), systemImage: "ellipsis.circle") }
            }
        }
    }
    /// Notices float over the terminal instead of taking rows from it.
    private var notices: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let notice = model.sessionNotice {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(notice).font(.footnote).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if model.diagnostic != nil {
                        Button(L10n.text("Copiar diagnóstico"), systemImage: "doc.on.doc", action: copyDiagnostic).labelStyle(.iconOnly)
                    }
                    Button(L10n.text("Cerrar aviso"), systemImage: "xmark") { model.sessionNotice = nil }.labelStyle(.iconOnly)
                }
                .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            if model.loadingHistory { ProgressView().padding(8).background(.regularMaterial, in: Circle()) }
        }.padding(8)
    }
    private var statusBar: some View {
        HStack(spacing: 12) {
            Label(statusText, systemImage: model.browsingHistory ? "clock.arrow.circlepath" : "eye")
                .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 8)
            if running && model.ready {
                if model.browsingHistory && model.ownsControl {
                    Button(L10n.text("Volver al final")) { model.returnToLive() }.buttonStyle(.borderedProminent)
                } else {
                    Button(L10n.text("Escribir desde aquí")) { model.claim() }.buttonStyle(.borderedProminent).disabled(!model.canClaim)
                }
            } else if !model.hostAvailable || running {
                Button(L10n.text("Volver a conectar"), systemImage: "arrow.clockwise") { model.reconnect() }.buttonStyle(.bordered)
            }
        }
        .frame(minHeight: 44).padding(.horizontal, 12).padding(.vertical, 4).background(.bar)
    }
    private var statusText: String {
        guard model.ready && running else { return model.terminalStatus }
        if model.browsingHistory { return L10n.text("Viendo el historial") }
        return L10n.text(model.canClaim ? "Solo lectura" : "Solo lectura. Autoriza el control desde el Mac.")
    }
    private var inputBar: some View {
        VStack(spacing: 6) {
            if composing || typing || dictation.listening || !draft.isEmpty {
                // A native field gets reliable iOS dictation; each edit reaches the terminal as it happens.
                TextField(L10n.text(dictation.listening ? "Escuchando…" : "Escribe o dicta un comando"), text: $draft)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($typing).submitLabel(.send).onSubmit(sendDraft)
                    .onChange(of: draft) { _, next in
                        let plain = TerminalLineEdit.plain(next)
                        guard plain == next else { draft = plain; return }
                        let edit = TerminalLineEdit.bytes(from: mirroredDraft, to: next)
                        if edit.isEmpty || model.input(edit) { mirroredDraft = next } else { releaseDraft() }
                    }
                    .padding(.horizontal, 8)
            }
            HStack(spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        barButton(L10n.text(typing ? "Ocultar teclado" : "Mostrar teclado"),
                                  symbol: typing ? "keyboard.chevron.compact.down" : "keyboard") {
                            if typing { typing = false } else { openKeyboard() }
                        }
                        barButton(L10n.text(dictation.listening ? "Dejar de dictar" : "Dictar"),
                                  symbol: dictation.listening ? "mic.fill" : "mic", action: toggleDictation)
                            .tint(dictation.listening ? .red : .accentColor)
                        ForEach([("Esc", "\u{1b}"), ("Tab", "\t"), ("^C", "\u{3}")], id: \.0) { key($0.0, $0.1) }
                        shortcuts
                        ForEach([("↑", "\u{1b}[A"), ("↓", "\u{1b}[B"), ("←", "\u{1b}[D"), ("→", "\u{1b}[C")], id: \.0) { key($0.0, $0.1) }
                    }.padding(.leading, 8)
                }.scrollIndicators(.hidden)
                Button(L10n.text("Enviar"), systemImage: "return", action: sendDraft)
                    .labelStyle(.iconOnly).buttonStyle(.borderedProminent).frame(minWidth: 44, minHeight: 40).padding(.trailing, 8)
            }
        }
        .buttonStyle(.bordered).padding(.vertical, 6).background(.bar)
        // Swiping the bar down puts the keyboard away, like a sheet.
        .gesture(DragGesture(minimumDistance: 20).onEnded { if $0.translation.height > 20 { typing = false } })
    }
    private func barButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: symbol, action: action).labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 40)
    }
    private func key(_ title: String, _ bytes: String) -> some View {
        Button(title) { send(bytes) }
            .font(.subheadline.monospaced()).frame(minWidth: 44, minHeight: 40)
            .accessibilityLabel(keyLabel(title))
    }
    private var shortcuts: some View {
        Menu {
            Section("Ctrl") {
                ForEach(["C", "D", "Z", "L", "R", "A", "E", "U", "W", "K"], id: \.self) { letter in
                    Button("Ctrl+" + letter) { send(String(UnicodeScalar(letter.unicodeScalars.first!.value & 0x1f)!)) }
                }
            }
            Section(L10n.text("Agentes")) {
                Button(L10n.text("Cambiar modo (⇧Tab)")) { send("\u{1b}[Z") }
                ForEach(["/clear", "/compact", "/resume"], id: \.self) { command in Button(command) { send(command + "\r") } }
            }
        } label: { Text("Ctrl").font(.subheadline.monospaced()).frame(minWidth: 44, minHeight: 40) }
        .accessibilityLabel(L10n.text("Atajos de control"))
    }
    /// The field only exists while composing, so it has to appear before it can take focus.
    private func openKeyboard() {
        composing = true
        DispatchQueue.main.async { typing = true }
    }
    private func send(_ bytes: String) { releaseDraft(); model.input(Data(bytes.utf8)) }
    private func sendDraft() {
        // The text is already on the terminal line; Enter runs it and the field starts over.
        releaseDraft(); model.input(Data("\r".utf8))
    }
    /// Leaves whatever is on the terminal line there and stops mirroring it.
    private func releaseDraft() { dictation.cancel(); mirroredDraft = ""; draft = "" }
    private func toggleDictation() {
        if dictation.listening { dictation.stop(); return }
        // Dictating needs no keyboard, so the terminal keeps the space.
        typing = false
        dictationPrefix = draft.isEmpty || draft.hasSuffix(" ") ? draft : draft + " "
        Task { await dictation.start(text: { draft = dictationPrefix + $0 }, failed: { model.sessionNotice = $0 }) }
    }
    private func copyDiagnostic() {
        guard let diagnostic = model.diagnostic else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        UIPasteboard.general.string = diagnostic + " | iOS " + UIDevice.current.systemVersion + " | AFK " + version + " (" + build + ")"
    }
    private func keyLabel(_ key: String) -> String {
        switch key {
        case "↑": return L10n.text("Flecha arriba")
        case "↓": return L10n.text("Flecha abajo")
        case "←": return L10n.text("Flecha izquierda")
        case "→": return L10n.text("Flecha derecha")
        case "^C": return L10n.text("Control C, interrumpir comando")
        default: return key
        }
    }
}

/// Hands-free dictation for the input bar. Partial results replace the draft as they
/// arrive, so corrections reach the terminal while the user is still speaking.
@MainActor
final class PhoneDictation: ObservableObject {
    @Published private(set) var listening = false
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start(text: @escaping (String) -> Void, failed: @escaping (String) -> Void) async {
        guard task == nil else { return }
        guard await Self.authorize() else { failed(L10n.text("Permite el micrófono y el reconocimiento de voz en Ajustes para dictar.")); return }
        guard task == nil, let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            failed(L10n.text("El dictado no está disponible ahora.")); return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // Audio stays on the iPhone whenever the language supports it.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
            engine.prepare()
            try engine.start()
        } catch { stopAudio(); failed(error.localizedDescription); return }
        self.request = request; listening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let done = error != nil || result?.isFinal == true
            Task { @MainActor in
                // A cancelled or replaced recognition must never retype text.
                guard let self, self.request === request else { return }
                if let transcript { text(transcript) }
                if done { self.finish() }
            }
        }
    }
    /// Stops listening; the recognizer may still refine the last words it heard.
    func stop() {
        guard listening else { return }
        stopAudio(); request?.endAudio()
    }
    func cancel() {
        guard let task else { return }
        task.cancel(); finish()
    }
    private func finish() {
        if listening { stopAudio() }
        request = nil; task = nil
    }
    private func stopAudio() {
        listening = false
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

struct PairingScanner: UIViewControllerRepresentable {
    let accept: (String) -> Void
    let unavailable: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(accept: accept, unavailable: unavailable) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .accurate, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() } catch { DispatchQueue.main.async { context.coordinator.unavailable() } }
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        coordinator.finished = true; controller.stopScanning()
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let accept: (String) -> Void
        var finished = false
        let unavailable: () -> Void
        init(accept: @escaping (String) -> Void, unavailable: @escaping () -> Void) { self.accept = accept; self.unavailable = unavailable }
        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            guard !finished else { return }; finished = true; scanner.stopScanning(); unavailable()
        }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            consume(addedItems, scanner: scanner)
        }
        func dataScanner(_ scanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            consume(updatedItems, scanner: scanner)
        }
        private func consume(_ items: [RecognizedItem], scanner: DataScannerViewController) {
            guard !finished else { return }
            for item in items {
                guard case .barcode(let barcode) = item, let value = barcode.payloadStringValue,
                      value.utf8.count <= 2048,
                      (try? SecureInvitation.decode(value)) != nil || value.hasPrefix("AFK2:") else { continue }
                finished = true; scanner.stopScanning(); accept(value); return
            }
        }
    }
}
