# Feature 5 — reconocer la terminal antes de escribir

Estado: implementado en la rama del PR; pendiente aceptación física. Responsable: JesusPaz. [Plan general](README.md).

## Diseño recomendado

La pista principal es el título textual de la tarea. La segunda línea aporta proyecto/herramienta confirmados. Un símbolo y acento de color estables representan el grupo. El control actual y el estado del proceso usan texto/indicadores propios, separados del color de identidad.

No asignar un color aleatorio nuevo por terminal ni cambiarlo con el título. No obligar a memorizar «azul = terminal correcta». Con muchas sesiones los colores se repiten; los nombres y el contexto siguen funcionando.

Fila propuesta:

```text
◇  Ajustar carga de lectura
   warden · Codex                  En este Mac
```

Cabecera fija: `◇ Load testing / Ajustar carga de lectura`; debajo, contexto y «Escribiendo en este Mac» o «Control desde iPhone». Repetir nombre/grupo en confirmaciones destructivas. En iPhone, una cabecera compacta conserva tarea y grupo, con detalles expandibles; no esconder todo el contexto para ganar una línea de terminal.

El símbolo de grupo puede ser una figura simple de SF Symbols, configurable dentro de un catálogo corto. No sobrecargarlo con significado de proceso. Herramienta va en texto en primera versión: no inventar logos ni mostrar Codex si no fue identificado. Selección: fondo/borde y contraste de texto distintos, además del acento de grupo. No teñir output ANSI ni usar una gran marca de agua que compita con lectura.

## Reglas de estabilidad y accesibilidad

- Grupo/orden/color/símbolo no cambian al modificar títulos ni por salida nueva.
- Nombre truncado conserva acceso al completo por detalle, tooltip en Mac y accesibilidad; nunca depender sólo de hover.
- VoiceOver anuncia nombre, grupo, contexto disponible y estado de control; los iconos decorativos no repiten información.
- Modo claro/oscuro, contraste aumentado, tamaños de texto y escala de grises deben mantener selección y nombres legibles. Usar colores semánticos/tokens comprobados, no fijar una paleta sin probarla.
- Si una sesión tiene nombre idéntico y mismo contexto, mostrar un sufijo corto estable también en cabecera.
- No pasar foco de escritura a otra sesión por ordenamiento, cierre o desaparición de la actual.

[W3C exige no depender sólo del color](https://www.w3.org/WAI/WCAG22/Understanding/use-of-color). [NN/g explica reconocimiento frente a recuerdo](https://www.nngroup.com/articles/recognition-and-recall/). Nuestra aplicación de esos principios es mantener pistas semánticas y espaciales coherentes; no una afirmación de que una figura concreta mejore memoria para todo el mundo.

## Criterios de cierre

Con ocho sesiones y nombres parecidos, Jesús identifica la tarea sin abrir varias terminales. Ensayar diez cambios dirigidos con marcador inocuo y comparar errores/tiempo contra la lista numerada. Repetir en gris, con VoiceOver y en iPhone; verificar que símbolo, color y estado no se confunden. Cero escrituras en destino incorrecto es el objetivo de aceptación, no garantía absoluta del producto.

Probar cambios automáticos de título mientras se busca una sesión: su posición y grupo deben permanecer. Probar cierre/ocultación de la seleccionada: ningún carácter posterior llega a otra terminal. Capturar resultados, no contenido sensible de sesiones reales.

Fuera de primera versión: buscador global, atajos configurables, vista de miniaturas y avisos repetitivos antes de cada comando. Evaluarlos sólo si identidad y grupos siguen siendo insuficientes.
