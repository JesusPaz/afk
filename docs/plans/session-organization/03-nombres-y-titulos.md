# Feature 3 — nombres útiles y títulos automáticos

Estado: implementado en la rama del PR; pendiente aceptación física. Responsable: JesusPaz. [Plan general](README.md).

## Resultado esperado

Ver «Mejorar scroll del iPhone» en lugar de «Terminal 3», acompañado por `afk · Codex` cuando esos metadatos estén disponibles. Permitir «Renombrar…» y «Usar título automático» siempre; la identidad de transporte continúa siendo sessionID.

## Precedencia y estabilidad

1. Alias manual no vacío: manda hasta que Jesús lo quite.
2. Título anunciado por el programa mediante secuencias de terminal, si existe y es válido.
3. Contexto confirmado, como directorio o nombre de proceso, cuando esté disponible.
4. Fallback estable «Terminal · A7F2», con sufijo derivado del ID para desambiguar; no renumerar al borrar otra.

No inventar descripción de tarea a partir de comandos, no usar un LLM ni extraer conversaciones privadas de archivos de Codex/Claude. Un título de aplicación puede cambiar; no reordenar la lista ni cambiar grupo/color por ello. Alias y grupo proporcionan estabilidad. Conservar título anunciado como detalle accesible si hay alias.

## Factibilidad

AFK ya usa SwiftTerm y tiene un `setTerminalTitle` vacío en la vista. Capturar OSC 0/2 con la API del parser autoritativo de Mac (`TerminalScreen`), no con regex sobre chunks ni sólo desde la vista seleccionada. Verificar callbacks exactos en la versión fijada. El título debe actualizarse también en sesiones ocultas y compartirse como metadato.

Que la interfaz de Codex/Claude muestre un nombre no implica que lo emita como título OSC. Probar versiones instaladas con fixtures/conversaciones sintéticas y registrar sólo eventos de título de prueba. Si no lo emiten, alias manual funciona desde el primer día; integración específica sería una segunda fase documentada. CWD por OSC 7 o shell integration tampoco se presupone disponible. No sondear todos los repos cada segundo para conseguir la rama Git.

[iTerm2 documenta títulos compuestos y dinámicos](https://iterm2.com/documentation-session-title.html), y [VS Code distingue nombres dinámicos de overrideName](https://code.visualstudio.com/docs/terminal/profiles). Son precedentes, no evidencia de compatibilidad universal de Codex/Claude.

## Datos y sincronización

Separar `userLabel`, `reportedTitle` y contexto opcional; derivar displayName. Mac publica cambios acotados y agrupados, no un mensaje por carácter. Mantener compatibilidad con `SessionInfo.name` como nombre derivado para clientes antiguos. Alias se persiste y enlaza por IDs con grabación; título remoto sólo se envía a quien ya tiene lectura.

Metadato anunciado es texto no confiable: acotar tamaño (120 caracteres después de un máximo de 2048 escalares Unicode), quitar controles/saltos y caracteres de dirección engañosos, renderizar como texto sin Markdown/links ejecutables. Probar Unicode y títulos divididos entre chunks. No interpretar títulos como estado de seguridad: «Producción» anunciado por una shell no es un entorno verificado.

## Criterios de cierre

- OSC 0/2 fragmentado actualiza el título una vez completo; ruido y payload grande no bloquean UI.
- Alias manual resiste cientos de cambios automáticos; quitar alias recupera título vigente.
- Duplicados se distinguen por contexto y, si sigue siendo necesario, sufijo corto visible.
- Sesión oculta/no seleccionada actualiza metadatos; orden e identidad visual permanecen estables.
- Mac/iPhone autorizados presentan el mismo nombre; cliente antiguo recibe fallback útil.
- Cambiar nombre no altera permisos, leases, rutas ni destino del input.
