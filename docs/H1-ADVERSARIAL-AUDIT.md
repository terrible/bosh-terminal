# H1 — Auditoría adversarial de la recuperación de archivos gestionados

**Fecha:** 2026-11-18  
**Repositorio:** `terrible/bosh-terminal`  
**Rama:** `fix/h1-transaction-recovery`  
**PR:** [#4 (borrador)](https://github.com/terrible/bosh-terminal/pull/4)  
**Issue:** [#3 (abierto)](https://github.com/terrible/bosh-terminal/issues/3)

> Esta auditoría examina únicamente la recuperación de archivos gestionados por `install_managed_file()`. No certifica seguridad ante cortes de energía, ni cubre exhaustivamente la integración de Zsh o los recursos anime.

## Hallazgos nuevos y correcciones

### A1 — Preparación incompleta del diario (corregido para caída de proceso)

**Observación:** la primera implementación creaba directamente `.$key.managed-pending` y después escribía sus archivos. Una interrupción antes de `record` dejaba un marcador incompleto que impedía la siguiente instalación.

**Corrección:** preparar el diario en una carpeta temporal privada `.$key.managed-prepare.XXXXXXXX`, comprobar contenido y hashes, y publicarlo con un renombrado atómico sin sustitución (`mv -nT`). La carpeta canónica de pendientes solo aparece al completar la preparación.

**Regresión:** `H1: crash during journal preparation must not block next install`.

**Seguimiento:** las carpetas de preparación incompleta ahora pueden retirarse de forma controlada mediante `bosh_managed_txn_collect()`. La limpieza comprueba identidad de ruta, propietario, modo privado, tipo de archivo, enlaces y nombres conocidos, y no usa `rm -rf`. Ante contenido ambiguo, conserva la carpeta y detiene el proceso. El análisis de concurrencia/TOCTOU sigue pendiente.

### A2 — Limpieza de entradas no reconocidas (corregido)

**Observación:** `bosh_managed_txn_finish()` eliminaba recursivamente el diario una vez conciliado, sin comprobar si había aparecido contenido ajeno en él.

**Corrección:** antes de retirar el diario solo se permiten entradas regulares conocidas: `record`, `next`, `previous` y `previous_destination`. Una entrada inesperada, un symlink o un archivo no regular detiene la limpieza y conserva evidencias.

**Regresión:** `H1: unexpected file inside journal must be preserved`.

### A3 — Aserción que no inspeccionaba el manifiesto (corregido)

Se corrigió una comparación literal defectuosa de `BOSH_MANIFEST[backup_path_b64]` en las pruebas. La nueva comparación usa expansión de la variable del manifiesto y verifica que no sea `-`.

### A4 — Interrupción durante la propia recuperación (corregido para caída de proceso)

**Observación:** una terminación después del commit de manifiesto, pero durante la eliminación del diario completado, dejaba copias persistentes bajo `.$key.managed-completed.*` que el siguiente instalador no recogía. Una preparación interrumpida también dejaba carpetas residuales.

**Corrección:** `bosh_managed_txn_collect()` reanuda la limpieza bajo el bloqueo del instalador/desinstalador. Los diarios completados se reconcilian con los hashes del estado nuevo o previo antes de borrar solo entradas conocidas; el archivo `record` se retira **al final** para admitir una segunda interrupción. Las carpetas de preparación no publicadas se inspeccionan antes de limpiar. Se utiliza `rm -f` para archivos individuales y `rmdir` para directorios vacíos, nunca borrado recursivo indiscriminado.

**Defensas:** se comprueban rutas con sufijos restringidos, UID del propietario, directorios modo `700`, archivos regulares sin symlink ni hardlink (`nlink=1`), contenido esperado y evidencia de estado del destino/manifiesto para residuos completados. Si falta `record` y quedan archivos, se detiene la limpieza.

**Regresiones añadidas:** caída durante recuperación tras commit de manifiesto, residuos `completed` tras interrupción, entrada ajena en `completed`, limpieza de `prepare`, `SIGKILL` tras retirar el primer snapshot, symlink en staging y hardlink en staging.

**Límites:** esta función requiere serialización mediante `flock`, que los puntos de entrada principales ya proporcionan. No elimina el riesgo de carreras con otros procesos del mismo UID ni proporciona durabilidad ante pérdida de energía.

## Evidencia automática

[GitHub Actions: ejecución 44399566717](https://github.com/terrible/bosh-terminal/actions/runs/44399566717)

| Comprobación | Resultado |
| --- | --- |
| H1: regresiones aisladas | **19/19 PASS** |
| Suite completa en contenedor Arch Linux | **11/11 módulos PASS** |
| Sintaxis Bash | PASS |
| ShellCheck | PASS |
| Jobs de CI | **2/2 PASS** |

Los escenarios H1 incluyen salida prematura, `SIGKILL` durante el registro de manifiestos, destino antes inexistente, actualización, modificación externa, interrupción antes de `mv`, confirmación ya realizada, permisos inseguros, symlink de diario, preparación interrumpida, manifiesto corrupto y archivo inesperado durante la limpieza.

## Riesgos y trabajo pendiente

1. **Durabilidad ante corte de energía:** `mv` atómico no implica persistencia. Falta diseñar `fsync` para contenido y directorios, o limitar explícitamente el contrato de recuperación a fallas de proceso.
2. **Residuos de staging y completed:** la recolección idempotente está implementada y probada, pero se requiere revisión independiente de carreras TOCTOU, escenarios de corrupción deliberada y estados históricos anteriores a esta corrección.
3. **Recuperación interrumpida:** se cubren cortes después del commit y durante la limpieza, incluso `SIGKILL` a mitad de la eliminación. Falta ampliar puntos de corte, fallos de I/O y comprobaciones de durabilidad.
4. **Concurrencia y TOCTOU:** verificar la cobertura de locking en todos los puntos de entrada; revisar cambios externos entre comprobación de hash y publicación.
5. **Propiedad/identidad de rutas:** se añadieron controles de UID, rutas y número de enlaces en la limpieza. Persisten revisiones de validación estricta de todos los manifiestos, rutas con traversal, permisos no canónicos y sustituciones concurrentes.
6. **Flujos independientes:** `install_anime_images()` y `integrate_zsh()` tienen protocolos de publicación diferentes; no se benefician automáticamente del diario de archivos gestionados.
7. **Otros hallazgos de auditoría:** revisar la ejecución privilegiada de `uninstall.sh`, validaciones de padres y consistencia de desinstalación (separados de H1).

## Criterio de integración

Mantener [PR #4](https://github.com/terrible/bosh-terminal/pull/4) **en borrador** y [issue #3](https://github.com/terrible/bosh-terminal/issues/3) **abierto** hasta completar revisión de seguridad y pruebas ampliadas. No fusionar en `main` ni usarlo como base para publicar el instalador online.

La CI verde demuestra los comportamientos probados, **no una garantía general de crash-consistency**.
