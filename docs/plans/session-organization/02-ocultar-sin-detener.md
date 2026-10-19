# Feature 2 — ocultar una terminal sin detenerla

Estado: implementado en la rama del PR; pendiente aceptación física. Responsable: JesusPaz. [Plan general](README.md).

## Resultado esperado

«Ocultar» retira una terminal de la lista principal sin finalizar la shell. «Ocultas (N)» permite reconocerla por título/contexto, revisar estado y volver a mostrarla. El término no promete pausar consumo ni supervivencia al cerrar AFK.

## Interacción

Menú de sesión → «Ocultar». Sin confirmación modal: ofrecer «Deshacer». En Ocultas: «Mostrar», «Mover a grupo…» y «Cerrar y quitar…» separadas. El listado de ocultas no adjunta todas las terminales ni recupera control por abrirse.

Al ocultar la seleccionada, mostrar un estado vacío que identifique la sesión ocultada; no dirigir teclado a otra shell. Al mostrar, conservar grupo y orden anteriores; seleccionar la recuperada sólo por acción explícita. El contador incluye activas ocultas; mostrar también cuáles terminaron mientras estaban ocultas. No reaparecer automáticamente con cada nueva salida.

Propuesta de alcance: ocultación local por dispositivo. Una tarea puede estorbar en Mac y seguir siendo útil en iPhone. Explicar «Ocultar en este dispositivo» en menú/ayuda. Ocultar no revoca permisos ni garantiza privacidad. El grupo sí conserva una identidad compartida.

## Implementación prevista

Separar colección de procesos de colección visible. Nunca liberar HostSession/PTY por filtrar una fila; conservar parser, grabación y fanout autorizado. No desmontar el componente que sea dueño efectivo del proceso. Mantener limpieza de input al abandonar la selección, sin modificar la autoridad de otros dispositivos.

Guardar preferencias por identidad Mac/sessionID, nunca por nombre. Resolver IDs ausentes tras reinicio; no resucitar sesiones ni duplicar registros. Conservar nombres/grupos en la grabación para encontrarlos después. Sesiones ocultas siguen contando contra el límite de procesos: si se alcanza, informar cuántas están ocultas y ofrecer abrir su lista.

## Criterios de cierre

- Un proceso de prueba sigue generando salida tras ocultar; mostrarlo devuelve la misma sesión/PID y salida.
- Ocultar/mostrar repetidamente no duplica shells, grabaciones ni listeners.
- Deshacer restaura posición/grupo sin reiniciar proceso.
- Ocultar en Mac no retira permiso ni oculta automáticamente en iPhone.
- Si termina oculta, se identifica como terminada; no se presenta como ejecutándose.
- En iPhone, ocultar/abandonar conserva las reglas actuales de borrar pantalla/caché y liberar control.

Referencia: [Apple, deshacer y rehacer](https://developer.apple.com/design/human-interface-guidelines/undo-and-redo). La decisión de que ocultar sea local es nuestra propuesta, no un requisito de Apple.
