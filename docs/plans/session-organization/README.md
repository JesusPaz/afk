# AFK — reconocer y organizar terminales

Fecha: 2026-10-19. Estado: implementado en la rama del PR; pendiente validación física de producto.
Responsable: JesusPaz. Seguimiento existente: [AFK #3](https://github.com/JesusPaz/afk/issues/3); crear o reutilizar issues específicos al implementar, no hay issues nuevos creados aquí.

## Problema y recomendación

Jesús entra en una terminal equivocada porque las sesiones se llaman Terminal 1, Terminal 2, etc. Las capturas muestran sesiones terminadas mezcladas con activas y poca información para distinguir tareas. La prioridad es reconocer el destino antes de escribir, no decorar la barra lateral.

Propuesta: **título de tarea legible + contexto secundario + grupos con nombre e identidad visual estable**. Repetir el mismo contexto en la cabecera del terminal y en el iPhone. Color y símbolo ayudan a explorar la lista; el texto identifica inequívocamente. No colorear toda la superficie ni alterar los colores ANSI de los programas.

Ejemplo ilustrativo (nombres ficticios, no estados detectados):

```text
▾ ◇ Load testing                         3
    Ajustar carga de lectura
    warden · Codex                 En este Mac
    Revisar latencia p95
    warden · Claude                Solo lectura
    Logs del servidor
    warden · zsh                   En este Mac
▾ □ AFK                                  1
    Mejorar scroll del iPhone
    afk · Codex                    En este Mac
  Ocultas                                2
  Terminadas                             1
```

Cabecera de la seleccionada: `◇ Load testing / Ajustar carga de lectura`, con proyecto/herramienta y control visibles. Las formas representan grupos, no estados. La selección usa fondo/borde y tipografía propios, no sólo el color del grupo.

## Investigación y qué se infiere

- [NN/g: reconocimiento frente a recuerdo](https://www.nngroup.com/articles/recognition-and-recall/): hacer visibles las pistas reduce la necesidad de recordar dónde estaba algo. Aplicación propuesta: nombres/contexto visibles antes de abrir; no constituye una prueba de que nuestro diseño ya reduzca errores.
- [VS Code: apariencia del terminal](https://code.visualstudio.com/docs/terminal/appearance): combina nombres, descripciones, iconos y color, y distingue indicadores de estado. Referencia de producto; no copiar todos sus ajustes.
- [iTerm2: títulos de sesión](https://iterm2.com/documentation-session-title.html): separa componentes del título y permite información dinámica. AFK debe distinguir alias elegido por la persona de título anunciado por un programa.
- [W3C: uso del color](https://www.w3.org/WAI/WCAG22/Understanding/use-of-color): el color no debe ser la única vía para transmitir significado. Lo usamos como principio aplicable a una interfaz nativa, sin afirmar una certificación WCAG de la app.
- [Safari: grupos de pestañas](https://support.apple.com/en-ie/guide/iphone/iph3028ebf68/ios): agrupar por tema y nombre ofrece un precedente para conjuntos de trabajo.
- [Apple: botones](https://developer.apple.com/design/human-interface-guidelines/buttons) y [deshacer](https://developer.apple.com/design/human-interface-guidelines/undo-and-redo): separar acciones destructivas y permitir revertir cambios reversibles. Cerrar un proceso no se puede deshacer; ocultar y reorganizar sí.

Estas fuentes respaldan principios y patrones. No prueban que una paleta, figura o número de grupos concreto sea óptimo para Jesús. La mejor combinación se valida con tareas reales y comparando errores de selección.

## Features

1. [Cerrar y quitar sesiones](01-cerrar-y-quitar.md): finalizar proceso y limpiar lista, preservando grabación.
2. [Ocultar sin detener](02-ocultar-sin-detener.md): apartar sesiones activas y recuperarlas.
3. [Nombres manuales y títulos automáticos](03-nombres-y-titulos.md): dar significado a cada terminal.
4. [Grupos de trabajo](04-grupos.md): reunir tareas por contexto, con orden estable.
5. [Identidad visual y orientación](05-identidad-visual.md): texto, símbolo, color y selección coherentes.

## Semántica compartida

| Acción | Proceso | Lista principal | Grabación |
| --- | --- | --- | --- |
| Ocultar | Sigue ejecutándose | Sale; aparece en Ocultas | Se conserva y sigue grabando |
| Mostrar | No cambia | Vuelve al lugar de su grupo | Se conserva |
| Cerrar y quitar | Se solicita finalizar y se verifica | Sale tras confirmar cierre | Se conserva |
| Quitar terminada | Ya terminó | Sale | Se conserva |
| Borrar grabación | No termina procesos | No gestiona sesiones vivas | Se borra explícitamente desde Historial guardado |

Salida natural de la shell: pasa a Terminadas. Si era la sesión seleccionada, se mantiene el resultado visible hasta que el usuario salga; no cambiar a otra shell escribible automáticamente. Cierre explícito: mostrar estado vacío con nombre de la sesión cerrada, sin transferir silenciosamente el teclado a otra tarea. Ocultar no pausa procesos ni conserva shells tras salir de AFK/reiniciar el Mac.

## Datos, autoridad y límites

Separar `lifecycle` (running/closing/ended), visibilidad local (visible/hidden), y organización (alias, grupo, orden). El ID permanece estable y es la clave de control; el título nunca identifica una sesión a nivel de protocolo.

El Mac es autoridad para alias y grupos; sólo dispositivos autorizados reciben metadatos de sus sesiones. Ocultar y colapsar son preferencias por dispositivo: ocultar en Mac no es retirar permisos al iPhone. Primera entrega: edición de organización en Mac, presentación en iPhone; permisos remotos de edición se diseñan aparte, no se heredan de permiso para escribir en la shell.

Persistir organización como metadatos privados locales; registrar versión de formato y enlazar grabaciones por ID, sin fingir que restaurar etiquetas restaura procesos. Las sesiones ocultas cuentan contra el límite de ocho procesos. Quitar terminadas debe dejar de consumir cupos; no subir el límite arbitrariamente.

## Base anterior a la implementación

Base revisada: main `18bfff5` en worktree `afk-history-fluidity`, con mejoras de scroll locales sin commit.

- `apps/apple/macOS/AFKMacApp.swift`: lista todas las sesiones; crea nombres numerados y conserva vistas para sesiones vivas. Selección por cambio de cantidad elige la última: revisar al añadir filtros/cierres.
- `packages/AFKHost/Sources/AFKHost/HostSession.swift`: `name` es inmutable; `terminate()` cambia running y llama al PTY, pero no retira la sesión de HostController.
- `HostController.create` limita por `sessions.count < 8`, incluyendo terminadas que permanezcan allí.
- `PTYProcess.terminate` envía SIGTERM al PID y cierra I/O. No demuestra por sí solo que todos los procesos hijos hayan terminado; probar grupo de procesos y confirmación real antes de prometer cierre completo.
- `apps/apple/Shared/TerminalSurface.swift`: `setTerminalTitle` no hace nada. El parser autoritativo `TerminalScreen` es candidato para capturar metadatos aunque la vista esté oculta.

## Orden recomendado y validación

Primero alias/títulos y cabecera contextual; después cerrar/quitar y ocultar; luego grupos y acentos visuales. Implementado junto a fluidez en un único worktree por compartir modelo, selección y superficie del terminal; preparar un solo PR coherente después de validación. No reescribir la terminal ni cambiar transporte salvo metadatos necesarios y negociados.

Prueba de producto: preparar ocho sesiones, dos con títulos parecidos, dos ocultas y una terminada; pedir a Jesús localizar tareas y comprobar contexto antes de escribir un marcador inocuo. Comparar con nombres numerados: tiempo hasta identificar, selecciones equivocadas, y confianza declarada. Objetivo propuesto: cero escrituras en sesión incorrecta en diez cambios dirigidos; repetir en iPhone y en escala de grises. Es criterio de aceptación propuesto, no resultado medido.

Cada documento incluye sus pruebas de cierre; no afirmar resuelto hasta aceptar en dispositivo físico.

## Implementación y evidencia local

- Worktree `~/personal/afk-history-fluidity`, rama `fix/iphone-history-fluidity`. Pendiente revisión y publicación de una versión.
- Mac: edita alias y grupos, reordena, oculta/muestra con deshacer, cierra y quita tras confirmar salida. iPhone: presenta grupos autorizados, oculta localmente y cierra con permiso; conserva compatibilidad con hosts anteriores.
- Títulos anunciados por OSC 0/2 y contexto de directorio OSC 7; alias manual tiene prioridad. No se lee la base privada de Codex/Claude ni se garantiza que toda herramienta anuncie un título.
- Cierre comprueba shell y grupo foreground; procesos desacoplados y servicios externos quedan fuera de esa garantía. Forzar cierre queda disponible si un proceso resiste.
- 107 pruebas Swift: 103 ejecutadas, 4 de integración omitidas por requerir infraestructura; cero fallos. Revalidación focalizada de transporte: 18 pasan. iPhone: 15 pruebas nativas pasan.
- Capturas nativas con datos sintéticos revisadas; pendiente prueba física por JesusPaz: diez cambios de tarea sin escribir en destino equivocado, títulos reales de Codex/Claude, dictado y fluidez con red móvil.
