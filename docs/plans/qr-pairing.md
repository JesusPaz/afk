# Emparejamiento con QR y confirmación local

Fecha: 2026-10-16. Estado: implementación local; **pendiente de validación física y entrega**.
Evidencia y pendientes: [validación](../qr-pairing-validation.md).
Responsable: JesusPaz. Seguimiento: [AFK #3](https://github.com/JesusPaz/afk/issues/3).

## Resultado esperado

Emparejar el iPhone con el Mac sin trasladar una cadena larga: mostrar un QR en
el Mac, escanearlo dentro de AFK, comparar un código en ambas pantallas y aprobar
en el Mac. El nuevo dispositivo queda vinculado, con **cero sesiones compartidas**.
Conservar «Pegar invitación» como alternativa con exactamente la misma confirmación.

La seguridad depende del secreto temporal, las identidades verificadas y la
aprobación local. El QR es otra representación de la invitación, no cifrado.
Una fotografía permite intentar el emparejamiento durante su vigencia; por sí
sola no debe permitir completarlo con este flujo.

## Base comprobada antes de implementar

- `SecureInvitation` en [SecureIdentity.swift](../../packages/AFKCore/Sources/AFKCore/SecureIdentity.swift)
  contiene servidor, host, huella, identificador, secreto de 256 bits y caducidad.
  Actualmente usa JSON/Base64 con prefijo `AFK2:`; dura cinco minutos.
- `HostTrustStore.authorize` comprueba la invitación y persiste el peer junto con
  su consumo en una sola escritura. Hay cinco intentos persistidos y hasta 16 peers.
- [SecureRelay.swift](../../packages/AFKCore/Sources/AFKCore/SecureRelay.swift)
  autoriza inmediatamente tras `hello`; **hoy no espera consentimiento en el Mac**.
  El límite inicial de conexión es de 15 segundos.
- `SecurePhoneRelay.pair` guarda el candidato en Keychain antes de recibir
  `welcome`; debe cambiar para no sustituir un vínculo válido durante un intento fallido.
- [AFKMacApp.swift](../../apps/apple/macOS/AFKMacApp.swift) presenta la invitación
  como texto y exige autenticación local para crearla.
- [AFKiOSApp.swift](../../apps/apple/iOS/AFKiOSApp.swift) tiene un formulario para
  pegar; [RemoteModel.swift](../../apps/apple/iOS/RemoteModel.swift) exige desbloqueo local.
- El transporte ya verifica WSS y la identidad del Mac fijada por la invitación.
  Los permisos de sesión se conceden por separado. Conservar ambas garantías.

## Alcance y decisiones

1. Un Mac y un iPhone por intento; una invitación vigente y un candidato pendiente
   por Mac. Conservar cinco minutos de vigencia y el límite de cinco intentos.
2. QR generado localmente, escáner nativo dentro de AFK y pegado manual alternativo.
   Sin servicios web para generar/leer códigos, nuevas dependencias ni permisos de fotos.
3. Confirmación explícita en Mac, autenticada con `LocalDeviceUnlock`, después de
   comparar el código mostrado en ambos dispositivos. Nunca aceptar automáticamente.
4. No implementar AirDrop, enlaces universales, Bluetooth, descubrimiento LAN,
   sincronización iCloud ni emparejamiento escribiendo un PIN en esta entrega.
5. No cambiar relay, E2EE, autoridad de terminal ni permisos de sesión salvo que
   una prueba demuestre una dependencia indispensable. No desplegar por un cambio documental.
6. No añadir permisos de lectura/control al completar el vínculo. El éxito ofrece
   abrir «Dispositivos → Sesiones y permisos» en el Mac.

## Experiencia de usuario

### Mac

- «Vincular iPhone» autentica al usuario y genera una invitación nueva. Reemplazar
  una invitación invalida la anterior y cualquier candidato asociado.
- Mostrar QR con margen libre, alto contraste y contador; no mostrar la cadena
  larga por defecto. Incluir «Copiar invitación», «Generar otra» y «Cancelar».
- Mostrar de forma secundaria el servidor seleccionado; las versiones publicadas
  mantienen `https://afk.jesuspaz.com` como valor inicial y respetan la elección guardada.
- Un candidato válido oculta el QR y muestra «Un iPhone quiere vincularse», un
  código legible y «Comprueba que este código aparece en tu iPhone».
- El nombre recibido del teléfono es una etiqueta no verificada. No usarlo como
  evidencia de identidad ni permitir textos enormes o caracteres de control.
- Botones: «Los códigos coinciden: vincular» y «Rechazar». El primero requiere
  autenticación local y vuelve a comprobar que el mismo candidato sigue vigente.
- Cerrar/cancelar, rechazar o agotar el tiempo invalida el intento y su invitación.
  No cerrar terminales ni revocar vínculos existentes como efecto de cancelar.

### iPhone

- «Vincular Mac» ofrece «Escanear QR» como acción principal y «Pegar invitación»
  como alternativa. Solicitar cámara únicamente al iniciar el escáner.
- Mostrar explicación localizada en `NSCameraUsageDescription`. Si se deniega
  la cámara, no está disponible o el escáner no es compatible, mantener pegado y
  explicar cómo habilitar el permiso; no bloquear toda la pantalla de vinculación.
- Procesar sólo el primer QR AFK válido y detener la captura. Los callbacks repetidos
  no pueden generar solicitudes paralelas. Códigos ajenos no abren URLs ni ejecutan acciones.
- Validar el payload antes de cualquier petición. Mostrar servidor y permitir
  continuar/cancelar antes de contactar un servidor nuevo; exigir desbloqueo local.
- Mostrar el código de comparación y «Confirma en tu Mac». Ofrecer cancelar.
  No mostrar terminales ni anunciar «Vinculado» antes del resultado autenticado.
- Si ya había un Mac vinculado, advertir del reemplazo antes de iniciar. Conservar
  su vínculo persistido hasta completar el nuevo; un fallo no lo borra.
- Al pasar a segundo plano, cancelar el intento, detener cámara y retirar secretos
  de la UI. Una transición de autenticación del sistema no debe confundirse con
  un segundo plano real; verificarlo en un iPhone físico.
- Tras éxito, guardar el nuevo vínculo y mostrar «Vinculado. Comparte sesiones
  desde tu Mac». No prometer acceso a una sesión aún no autorizada.

## Protocolo y límites de confianza

### Compatibilidad explícita

El consentimiento no puede ser una opción que un cliente omita para entrar por
el flujo antiguo. Usar una nueva versión de invitación (`AFK3:` / schema 3) para
nuevos vínculos, manteniendo el secreto y la identidad fijada del formato actual.

- Las apps nuevas rechazan `AFK2:` para nuevas altas con una indicación de actualizar
  ambas apps y regenerar la invitación. QR y pegado comparten este comportamiento.
- El Mac nuevo exige el intercambio de consentimiento para todo certificado no
  registrado, incluso si el cliente envía un `hello` antiguo o campos incompletos.
- Los peers ya vinculados conservan su reconexión v2 con certificado exacto;
  no se los obliga a emparejar de nuevo ni se abre una excepción para peers nuevos.
- Mantener WSS, rutas y TLS/ALPN existentes si permiten los mensajes nuevos.
  Versionar la ceremonia de alta explícitamente dentro del intercambio; no cambiar
  todo el protocolo de sesiones sólo para incorporar una confirmación.
- No aceptar `welcome` de un alta sin el estado y el identificador de aprobación
  esperados. Ninguna caída de compatibilidad vuelve al alta automática.

### Estados mínimos

```text
Invitación activa
  → secreto y contexto válidos, identidad TLS del candidato comprobada
  → candidato reservado / esperando aprobación
  → autenticación y aprobación local del candidato exacto
  → persistencia atómica del peer + consumo de invitación
  → welcome autenticado → persistencia del vínculo en iPhone

Cualquier cancelación, rechazo, vencimiento o pérdida de conexión antes del commit
  → cierre del intento, sin nuevo peer confiable ni permisos
```

Separar validar/reservar y confirmar en `HostTrustStore`/`SecureHostRelay`; no
limitarse a poner un diálogo después de `authorize`, porque entonces el peer ya
estaría registrado. La reserva del candidato es transitoria en RAM; el hash,
contador e invalidación de la invitación conservan sus garantías persistidas.

- Vincular el candidato a invitación, servidor canónico, host/client IDs,
  certificados verificados, conexión concreta y generación del intento.
- Antes de consentimiento, permitir únicamente mensajes acotados del emparejamiento.
  Nunca emitir `clientConnected`, `welcome`, listas, salida de terminal ni aceptar
  comandos de sesión. TLS establecido no equivale a alta aprobada.
- Mantener el límite de 15 segundos para alcanzar un candidato validado. Después,
  dar hasta 120 segundos para confirmar, sin superar la caducidad original.
  Actualizar también la espera del iPhone (hoy 300 intervalos de 50 ms), no sólo
  el timeout del Mac. Medir tiempo monotónico; retroceder el reloj no alarga la espera.
- Un segundo candidato no reemplaza al primero ni cambia su código. Rechazarlo sin
  reiniciar temporizadores. Aplicar el presupuesto de intentos también durante
  la espera; no crear colas de diálogos ni estados ilimitados.
- Aprobación, vencimiento, reemplazo, revocación y desconexión compiten por una
  única transición de estado. Comprobar generación y conexión después de cada
  `await`, especialmente después del desbloqueo local.
- Persistir peer y consumo antes de emitir éxito. Si falla Keychain, cerrar y no
  anunciar éxito. Si falla persistir la invalidación, deshabilitar altas y cerrar
  candidatos hasta resolverlo; no dejar operativa una invitación que la UI dice cancelada.
- Al cancelar/rechazar un candidato, consumir o invalidar su invitación para que
  no pueda insistir con el mismo QR. «Generar otra» es una acción local explícita.
- Bloquear la sesión del Mac cancela la ceremonia y retira el QR. Desbloquear no
  la reanuda automáticamente; verificar la notificación de bloqueo en hardware real.
- Un reinicio nunca restaura un candidato esperando aprobación ni continúa una
  aprobación anterior. Invalidar invitaciones recuperadas al iniciar el host.
- Si se corta la red **después del commit del Mac**, el Mac puede conservar un peer
  sin que el teléfono haya recibido éxito. No afirmar atomicidad entre dispositivos:
  mostrarlo en Dispositivos para revocarlo; el iPhone conserva su vínculo anterior
  y puede empezar una invitación nueva. No rollback remoto de confianza ya confirmada.

### Código de comparación

El código es una comprobación visual adicional, **no una contraseña corta ni un
sustituto del secreto de 256 bits**. Debe identificar el mismo intento y los mismos
certificados en ambas pantallas; no basta con comparar nombres o el ID de invitación.

- Construir un resumen con SHA-256 de una transcripción canónica y con etiqueta de
  dominio: versión de ceremonia, servidor canónico, host/client IDs, ID de invitación,
  huellas completas de ambos certificados y nonces frescos de ambas partes.
- El nonce del Mac se genera después de fijar el candidato y viaja dentro de la
  conexión E2EE. Ambos calculan el código; no confiar en un código presentado por el peer.
- Especificar una única serialización inequívoca, con campos delimitados por longitud
  u otro formato determinista; nunca concatenar cadenas ambiguas ni depender del orden de JSON.
- Presentar ocho dígitos agrupados `1234 5678`, derivados de manera determinista del
  resumen. Documentar algoritmo y vectores antes de integrarlo. No registrar código,
  transcripción, nonces ni secreto en logs.
- Ocho dígitos pueden colisionar: no presentar el código como prueba criptográfica
  absoluta. La defensa mantiene secreto, pin del Mac, prueba de posesión de la clave
  del teléfono, nonces frescos, presupuesto de intentos y consentimiento local.
- La implementación debe revisar este diseño antes de fusionar; esta auditoría de
  alcance no sustituye una revisión criptográfica independiente.

## QR, secretos y validaciones

- Generar el QR con Core Image y leerlo con una API nativa de Apple. Comprobar soporte
  del escáner en ejecución. No introducir librerías de terceros para estas operaciones.
- El contenido es la invitación completa, no una URL web que suba el secreto al
  relay, navegador, servicio de acortamiento o proveedor de QR.
- Reutilizar una sola función de análisis/validación para QR y pegado. Límite total
  de entrada antes de Base64/JSON; límites también por campo y protocolo conocido.
- Validar caducidad, identidad y URL con las reglas actuales: HTTPS/WSS con certificados
  válidos; HTTP sólo en loopback para desarrollo, sin redirecciones ni relajación de TLS.
- El servidor puede ser personalizado. Escanear no implica confiar en él: mostrar
  su origen real y pedir continuar antes de una solicitud. Un QR reemplazado por un
  atacante sigue siendo un riesgo del canal visual; comparar con el Mac que el usuario ve.
- Verificar que el payload máximo admitido cabe en el QR con el nivel de corrección
  elegido. Si no cabe o no es legible, ofrecer pegado; jamás truncar el secreto.
- No copiar automáticamente, exportar imagen, guardar capturas ni incluir invitaciones
  en analytics, errores o historial. «Copiar» será explícito y con expiración del
  portapapeles cuando la plataforma lo permita, sin borrar contenido posterior ajeno.
- Retirar el QR al reservar candidato, cancelar, caducar o terminar. La retirada de
  pantalla no garantiza borrar capturas previas ni eliminación segura de RAM.
- VoiceOver debe describir propósito, tiempo y acciones, sin leer el secreto. El
  código de comparación sí debe ser accesible. Mantener español e inglés.

## Pruebas de aceptación

| ID | Escenario | Resultado verificable |
| --- | --- | --- |
| P01 | QR real y pegado del mismo formato | Mismo parser y ceremonia; no atajo de autorización. |
| P02 | QR válido, sin aprobación en Mac | Ningún nuevo peer persistido, evento de conexión ni acceso a sesiones. |
| P03 | Comparación y aprobación válidas | Una escritura atómica en Mac antes de welcome; vínculo guardado en iPhone después; cero permisos. |
| P04 | Código/transcripción | Vectores iguales en ambos roles; cambiar cualquier identidad, nonce o contexto cambia el resumen; no afirmar ausencia de colisiones del código truncado. |
| P05 | Rechazar, cerrar, cancelar o expirar | Sin alta; QR invalidado; reiniciar no lo reactiva; pegado del QR anterior falla. |
| P06 | Dos teléfonos y múltiples callbacks del escáner | Un candidato; código estable; ninguna aprobación se transfiere a otra conexión. |
| P07 | Aprobar mientras expira, se reemplaza el QR o se corta todo acceso | Una transición; aprobación tardía rechazada, también tras el prompt de autenticación. |
| P08 | Cinco intentos y flood durante espera | Presupuesto persistido, memoria acotada y sin tormenta de diálogos; sin renovación del tiempo. |
| P09 | Fallo Keychain del Mac al aprobar/cancelar | Sin éxito ni alta en RAM inconsistente; altas cerradas si no se puede persistir invalidación. |
| P10 | Error/red caída/Keychain fallido en iPhone | No sobrescribe el vínculo anterior; informa el resultado; contempla peer huérfano posterior al commit del Mac. |
| P11 | Mensajes de terminal antes de aprobación | List/create/attach/input/resize y otros comandos rechazados; ninguna salida o metadato de sesiones. |
| P12 | Payload inválido, ajeno, enorme, vencido, URL no permitida o TLS/pin incorrecto | Rechazo acotado; ninguna petición antes de validar y confirmar origen; sin abrir enlaces externos. |
| P13 | Compatibilidad | AFK2 rechazado para altas nuevas; hello antiguo no evita aprobación; peer previamente vinculado sigue reconectando. |
| P14 | Cámara denegada/no compatible, VoiceOver y ES/EN | Pegado usable; mensajes claros; no se expone el secreto; captura finaliza al salir. |
| P15 | iPhone a segundo plano; Mac se bloquea, reinicia o pierde conexión | Intento invalidado; sin aprobación restaurada ni permisos nuevos. |
| P16 | Desfase de relojes y expiración durante Face ID/Touch ID | No extiende vigencia; transición de autenticación no cancela erróneamente por segundo plano. |
| P17 | Dos dispositivos físicos por WSS público | Escaneo legible, códigos coincidentes, confirmación, denegación, repetición rechazada, permisos manuales y revocación. |

Usar pruebas unitarias con reloj inyectable y persistencia que pueda fallar para
las transiciones; integración nativa real para la ceremonia y límites de transporte.
No sustituir estas comprobaciones por tests de getters o una captura de pantalla.
El código de comparación y las carreras deben probarse con entradas deterministas.
El host CLI de integración debe aprobar explícitamente un candidato desde el
harness; no introducir un modo de autoaprobación en las apps distribuidas.

## Secuencia de implementación y salida

1. **Estado de alta y compatibilidad.** Definir mensajes/serialización, reserva y
   commit. Verificar P02–P13 antes de conectar la UI; reutilizar límites existentes.
2. **Confirmación local y UI de espera.** Integrar el estado con el Mac y el iPhone;
   verificar cancelación, generaciones, persistencia y autenticación.
3. **QR y escáner.** Añadir presentación y permiso de cámara sobre el mismo flujo;
   verificar P01, P12, P14 y tamaño/legibilidad del payload.
4. **Validación completa.** `swift test`, integración PTY local y por WSS, builds
   Mac/iPhone, pruebas físicas P17; ejecutar las comprobaciones requeridas de Go
   con PostgreSQL real si cambia transporte/relay o como puerta de entrega del repo.
5. **Entrega coordinada.** Documentar incompatibilidad de invitaciones antiguas;
   nueva release Mac firmada/notarizada y nuevo build TestFlight. Actualizar las dos
   apps antes de generar QR; no reemplazar archivos de releases existentes.

Criterio de cierre: todos los casos automatizables aprobados, validación física
registrada por Jesus, ninguna ruta alternativa de alta automática, y artefactos
verificados de ambas apps. Hasta entonces, reportar exactamente qué queda pendiente.

## Auditoría con las reglas de Karpathy

Auditoría realizada sobre este documento y el código actual, no sobre una
implementación futura. No se ejecutaron pruebas funcionales para un cambio documental.

| Regla | Hallazgo | Resolución incorporada |
| --- | --- | --- |
| Pensar antes de programar | «Añadir QR» ocultaba un cambio de autorización: hoy se persiste y acepta inmediatamente. | Separar reserva/aprobación/commit; describir estados y fallos antes de UI. |
| Pensar antes de programar | No había decisión de compatibilidad ni duración de la espera humana. | AFK3 para altas, reconexión existente preservada, 15 s iniciales y hasta 120 s de aprobación dentro de 5 min. |
| Simplicidad primero | QR, AirDrop, Bluetooth y PIN a la vez multiplican superficie y pruebas. | Sólo QR y pegado compartiendo parser, sin dependencias nuevas ni descubrimiento. |
| Simplicidad primero | Comparar nombres o mostrar un código arbitrario daría confianza falsa. | Código derivado de contexto/identidades/nonces; límite explícito de colisiones; no sustituye secreto ni aprobación. |
| Cambios quirúrgicos | Cambiar todo el protocolo, el relay o las sesiones no se justifica por esta ceremonia. | Cambiar sólo alta, persistencia del candidato, UI y permiso de cámara; conservar transporte y permisos. |
| Cambios quirúrgicos | El intento fallido actual puede reemplazar el vínculo guardado del teléfono. | Persistir el reemplazo sólo al recibir éxito autenticado; probar fallos de almacenamiento. |
| Ejecución verificable | «Seguro y fácil» no indica cómo detectar regresiones. | Matriz P01–P17, vectores de transcripción, pruebas de carreras y prueba física. |
| No ocultar incertidumbre | No existe commit atómico entre Keychains de dos dispositivos ni código corto sin colisiones. | Documentar peer huérfano, recuperación manual y límites; no prometer garantías imposibles. |

**Resultado:** plan acotado y verificable para implementar. No demuestra seguridad
absoluta ni autoriza declarar la función lista. Antes de escribir código, concretar
los mensajes y vectores del resumen conforme a estas invariantes; cualquier
necesidad de ampliar alcance debe justificarse con evidencia.

Referencias: [seguridad actual](../security.md), [E2EE](../e2ee.md),
[escáner nativo de Apple](https://developer.apple.com/documentation/visionkit/scanning-data-with-the-camera).
