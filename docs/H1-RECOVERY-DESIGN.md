# H1 — Diseño de recuperación transaccional (propuesta)

> Estado: **diseño pendiente de implementación y pruebas**.  
> Seguimiento: [Issue #3](https://github.com/terrible/bosh-terminal/issues/3).  
> Base de trabajo: `fix/h1-transaction-recovery` (derivada de `fix/h2-test-isolation`).  
> No utilizar este documento como evidencia de que H1 esté corregido.

## Problema reproducido

`install_managed_file()` reemplaza el destino mediante `mv` y solo después invoca `write_manifest()`. Una interrupción entre ambas operaciones puede dejar el archivo nuevo sin el manifiesto que lo relaciona con el respaldo original.

En una prueba con HOME temporal, interrumpir `write_manifest()` mediante `exit 86` produjo:

- Destino reemplazado por el candidato.
- Ausencia de `starship_manifest`.
- Respaldo original existente.
- Reintento que clasifica el candidato como preexistente e idéntico y registra `backup_path_b64=-`.

La reproducción no simula todavía `SIGKILL` ni pérdida de energía.

## Objetivo e invariantes

1. **No perder la asociación con el respaldo original.** Cualquier reemplazo debe tener una operación persistente recuperable *antes* de cambiar el destino.
2. **No sobrescribir cambios externos.** Ante contenido o tipo no reconocidos, preservar y detener la recuperación con diagnóstico.
3. **No ejecutar archivos de estado.** Los manifiestos y diarios son datos, se validan de forma estricta; nunca se cargan con `source` o `eval`.
4. **No confiar en rutas arbitrarias del diario.** Reconstruir el destino a partir de una clave conocida y validar directorios, symlinks, hashes, permisos y que los snapshots estén en el área privada gestionada.
5. **Mantener el estado anterior hasta el commit.** Un manifiesto anterior y su respaldo original no se invalidan hasta la confirmación del nuevo estado.
6. **Reentrada idempotente.** La recuperación debe funcionar aunque ella misma se interrumpa.
7. **Un único escritor.** Instalar, desinstalar y recuperar deben operar con el mismo bloqueo exclusivo.
8. **No tratar `EXIT` como garantía de recuperación.** `SIGKILL`, fallos del kernel y cortes de energía no ejecutan traps.

## Propuesta: diario write-ahead persistente

Por cada clave administrada, preparar un registro privado en `$BOSH_STATE` (p. ej., `<key>_pending`), escrito atómicamente antes de publicar el archivo. El registro debe contener, en un formato versionado:

- Clave y destino esperado en Base64, cotejado con una lista fija de destinos.
- SHA-256 esperado del destino anterior, o marca inequívoca de ausencia.
- SHA-256 esperado del candidato.
- Existencia y SHA-256 del manifiesto anterior, o marca de ausencia.
- SHA-256 del manifiesto nuevo previsto.
- Identidad del respaldo original, hash, modo y metadatos de titularidad.
- Identidad y SHA-256 del snapshot persistente del estado inmediatamente anterior (para actualizaciones).
- Fase lógica derivable de archivos verificados; no depender únicamente de una fase declarada.

El snapshot transaccional **no debe registrarse como temporal eliminable por los traps habituales**. Utilizar archivos persistentes en un directorio privado con creación exclusiva y validación de tipo/propietario. Reutilizar las rutinas de restauración por hash cuando sea seguro, pero no suponer que un snapshot sigue existiendo sin comprobarlo.

### Orden de operaciones propuesto

1. Adquirir bloqueo exclusivo y **resolver cualquier operación pendiente** antes de evaluar nuevos manifiestos o modificar destinos.
2. Validar el archivo fuente, el destino, el manifiesto previo y los respaldos asociados.
3. Crear y verificar el respaldo original, cuando corresponda, y un snapshot persistente del destino anterior si se necesita para rollback.
4. Preparar y validar el manifiesto nuevo, sin publicarlo todavía.
5. Publicar atómicamente el diario pendiente con la identidad del estado anterior y nuevo. **Si esto falla, no reemplazar el destino.**
6. Publicar el candidato en el destino. Verificar SHA-256.
7. Publicar atómicamente el nuevo manifiesto. Verificarlo.
8. Retirar el diario pendiente y los snapshots auxiliares **solo cuando el estado publicado esté verificado**. Los respaldos originales permanentes no se eliminan.

Para una garantía ante **corte de energía**, además de procesos terminados, hacen falta barreras de durabilidad de archivos y directorios (`fsync`/equivalente); `mv` atómico por sí solo **no** garantiza durabilidad. Esta parte debe definirse, implementarse y probarse específicamente. No prometer resistencia a cortes de energía solo por añadir un diario.

## Recuperación al iniciar instalador *y* desinstalador

Bajo el bloqueo, leer el diario como datos y validar rutas y hashes. Comparar estado físico y manifiesto con las identidades **anterior** y **nueva** del diario:

| Destino | Manifiesto | Acción propuesta |
| --- | --- | --- |
| Anterior o ausente según diario | Anterior | Sin publicación efectiva: completar rollback/limpieza del diario, preservando respaldo |
| Nuevo | Anterior o ausente | Publicación incompleta: restaurar anterior usando snapshot/respaldo verificado y conservar el manifiesto anterior |
| Nuevo | Nuevo | Commit efectuado: validar asociación y limpiar snapshot/diario sin revertir |
| Otro contenido, symlink, directorio inesperado, hash inválido | Cualquiera | **Fallar en modo seguro**: no sobrescribir ni eliminar; conservar evidencias para intervención |
| Anterior | Nuevo | Estado inconsistente: **no modificar automáticamente** hasta definir resolución probada |

La restauración y la limpieza también deben ser idempotentes ante una segunda interrupción. Si el estado está ambiguo, preferir preservar archivos y notificar exactamente las rutas seguras al usuario, sin ejecutar borrados generales.

## Matriz mínima de pruebas de regresión

1. Primera instalación: destino anterior presente, interrupción **antes** y **después** del `mv`, antes del manifiesto, antes de limpiar diario.
2. Primera instalación: destino originalmente ausente, mismos puntos de interrupción.
3. Actualización con manifiesto previo y respaldo original ya existente.
4. Reintento de instalación y desinstalación con diario pendiente en cada fase; hashes y permisos de originales preservados.
5. Contenido externo editado durante interrupción; symlink en destino, padre, diario, backup y snapshot; rutas malformadas; hash inconsistente; bloqueo concurrente.
6. Error ordinario de `write_manifest` y recuperación posterior.
7. Terminación forzada del hijo de prueba con `SIGKILL` (sin tocar el proceso de pruebas principal).
8. Interrupción durante la propia recuperación; segunda recuperación segura e idempotente.
9. `bash -n`, ShellCheck, suite completa y ejecución con variables `BOSH_*` externas y centinelas.
10. Revisar por separado el mismo patrón `mv` + `write_state` de `install_anime_images()`; no declarar resuelta la consistencia de anime sin cubrirla.

## Decisiones pendientes antes de implementar

- Formato concreto del diario y validaciones del parser (con retrocompatibilidad de manifiestos v1 y legados).
- Estrategia de durabilidad real en Arch Linux sin dependencias opcionales inseguras.
- Vías de recuperación para instalaciones preexistentes afectadas **antes** de incorporar el diario (sin intentar inferir un respaldo a partir de nombres ambiguos).
- Política ante operación pendiente al desinstalar: recuperar primero o detenerse con diagnóstico.
- Integración exacta con `bosh_cleanup_temps`, snapshots, locking y restauración.

**Regla de entrega:** no merge, release ni instrucciones de instalación pública hasta que el mecanismo esté implementado y la matriz de pruebas esté respaldada por resultados reproducibles.
