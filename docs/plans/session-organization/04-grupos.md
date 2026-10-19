# Feature 4 — grupos de trabajo con nombre

Estado: implementado en la rama del PR; pendiente aceptación física. Responsable: JesusPaz. [Plan general](README.md).

## Resultado esperado

Crear «Load testing», reunir sus terminales, colapsar el grupo y volver a encontrarlo en el mismo lugar. Un grupo representa contexto de trabajo, no una shell, carpeta real ni frontera de permisos.

## Interacción

«Nuevo grupo…» pide nombre; símbolo y color tienen valores sugeridos y se pueden cambiar. Crear grupos vacíos es válido. Mover con menú «Mover a grupo…»; arrastrar y soltar queda aplazado. El orden se cambia mediante acciones del menú. Mostrar «Sin grupo» cuando haga falta. Una sesión pertenece a cero o un grupo en la primera versión, sin grupos anidados ni etiquetas múltiples.

Orden manual estable de grupos y terminales; nunca mover por actividad, título o último acceso. Colapsar no oculta de forma persistente ni termina sesiones; contador informa cuántas contiene. Crear terminal desde un grupo la asigna allí; el botón global usa Sin grupo para evitar contexto implícito ambiguo.

Eliminar grupo mueve sesiones a Sin grupo y permite deshacer: no termina ni oculta sus miembros. «Cerrar todas» se aplaza para evitar introducir cierre masivo en la primera entrega. Estado de expandido/colapsado y ocultación son por dispositivo. Nombre, pertenencia, símbolo y color pertenecen a la organización definida en Mac.

## Modelo implementado

Group: ID estable, nombre, símbolo de catálogo acotado, color token y orden. SessionMetadata: groupID opcional, orden y alias. No duplicar sesiones para moverlas. Guardado atómico/versionado en Mac; si groupID queda huérfano, usar Sin grupo.

iPhone muestra únicamente grupos con sesiones autorizadas y los cuenta según su propia visibilidad autorizada; no revelar nombres/conteos de grupos privados. Primera entrega permite editar desde Mac, no asumir que permiso de control de shell autoriza modificar organización global. Metadatos viajan por canal E2EE existente con campos opcionales y fallback para clientes antiguos.

Persistir grupos tras reiniciar, pero no recrear shells automáticamente; grabaciones conservan referencia/nombre de grupo para consulta histórica. Un grupo vacío tras reinicio no representa una sesión restaurada.

## Criterios de cierre

- Crear, renombrar, mover, reordenar, colapsar y eliminar no cambia PID ni autoridad de input.
- Dos grupos con nombres parecidos se distinguen; validar nombres vacíos y límites.
- Eliminar grupo conserva sesiones/grabaciones y permite revertir organización.
- Reinicio conserva metadatos y no arranca comandos ni shells sin petición.
- Mac/iPhone mantienen identidad compartida, pero expandido/oculto es independiente.
- Usuario remoto no ve grupos sin acceso ni conteos de sesiones ajenas.

Referencia: [grupos con nombre por tema en Safari](https://support.apple.com/en-ie/guide/iphone/iph3028ebf68/ios). La pertenencia única y edición inicial en Mac son elecciones propuestas para mantener el alcance manejable.
