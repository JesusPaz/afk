# Feature 1 — cerrar y quitar una sesión

Estado: implementado en la rama del PR; pendiente aceptación física. Responsable: JesusPaz. [Plan general](README.md).

## Resultado esperado

Al elegir «Cerrar y quitar…», la shell termina y su fila desaparece. Su historial sigue en Historial guardado. Una sesión ya terminada tiene «Quitar de la lista», sin una falsa operación de terminar.

No usar «Borrar sesión» para mezclar cierre de proceso y eliminación del historial. [Apple distingue acciones destructivas](https://developer.apple.com/design/human-interface-guidelines/buttons); proponemos confirmar el cierre porque puede cortar trabajo en curso.

## Interacción

Menú contextual y menú Sesión: «Cerrar y quitar…». Diálogo con título de sesión y grupo: «Se detendrá esta terminal y sus procesos vinculados. La grabación se conservará». Cancelar por defecto; botón destructivo «Cerrar y quitar». La descripción final debe ajustarse a lo que garantice realmente el control de procesos implementado.

Mientras cierra: estado «Cerrando…», entrada desactivada y acción idempotente. Quitar fila tras salida confirmada; si no termina, conservarla y ofrecer «Forzar cierre…» con explicación. Nunca mostrar éxito sólo porque se envió una señal. No prometer detener procesos desacoplados, servicios o tareas remotas iniciadas por la shell.

Si estaba seleccionada, mostrar «Sesión cerrada» y botones para elegir otra o crear una; no seleccionar automáticamente otra terminal con foco de escritura. Cerrar una fila no seleccionada no altera el foco actual.

Cuando una shell sale por sí sola, mover a Terminadas, conservando la vista de salida si estaba seleccionada. «Quitar de la lista» es reversible a nivel de listado/grabación; no restaura la shell. Borrado de grabación sigue siendo otra acción.

## Implementación prevista

Coordinar en HostController, no eliminar sólo la vista SwiftUI. Revisar `HostSession.terminate`, `PTYProcess` y callback onExit: PID/grupo, señal, reap, timeout y estado confirmado. Liberar permisos, referencias de renderer, observadores, tareas y cupo; finalizar grabación. Publicar retirada de sesión a clientes autorizados y vaciar entrada/caché remota antes de seleccionar otra.

Permiso remoto existente para terminar sigue siendo requisito. Separar semántica vieja de terminate y nueva retirada para clientes anteriores; no asumir que todos actualizan juntos. El máximo de ocho debe contar recursos vivos/cerrando, no filas de archivo.

## Criterios de cierre

- Shell activa, terminada, salida espontánea y cierre repetido tienen resultados deterministas.
- Prueba real de PTY: shell y proceso foreground/grupo de prueba salen; un proceso desacoplado se documenta como límite.
- Un cierre fallido no oculta una shell aún activa ni libera su cupo antes de tiempo.
- Cerrar no borra grabación; puede abrirse después y contiene salida final confirmada.
- Tras cerrar, ningún input pendiente llega a otra sesión; iPhone pierde acceso a la sesión retirada.
- Cerrar ocho sesiones y crear otras no acumula recursos ni deja cupos ocupados por terminadas.

Fuera de alcance: matar servicios externos, restaurar procesos, borrar historial automáticamente.
