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

**Límite:** una caída mientras se prepara puede dejar una carpeta de staging privada con snapshots. La limpieza automática, incluyendo comprobación de propiedad y resistencia a ataques de rutas, está pendiente. No debe hacerse `rm -rf` indiscriminado sobre esos directorios.

### A2 — Limpieza de entradas no reconocidas (corregido)

**Observación:** `bosh_managed_txn_finish()` eliminaba recursivamente el diario una vez conciliado, sin comprobar si había aparecido contenido ajeno en él.

**Corrección:** antes de retirar el diario solo se permiten entradas regulares conocidas: `record`, `next`, `previous` y `previous_destination`. Una entrada inesperada, un symlink o un archivo no regular detiene la limpieza y conserva evidencias.

**Regresión:** `H1: unexpected file inside journal must be preserved`.

### A3 — Aserción que no inspeccionaba el manifiesto (corregido)

Se corrigió una comparación literal defectuosa de `BOSH_MANIFEST[backup_path_b64]` en las pruebas. La nueva comparación usa expansión de la variable del manifiesto y verifica que no sea `-`.

## Evidencia automática

[GitHub Actions: ejecución 44394703710](https://github.com/terrible/bosh-terminal/actions/runs/44394703710)

| Comprobación | Resultado |
| --- | --- |
| H1: regresiones aisladas | **12/12 PASS** |
| Suite completa en contenedor Arch Linux | **11/11 módulos PASS** |
| Sintaxis Bash | PASS |
| ShellCheck | PASS |
| Jobs de CI | **2/2 PASS** |

Los escenarios H1 incluyen salida prematura, `SIGKILL` durante el registro de manifiestos, destino antes inexistente, actualización, modificación externa, interrupción antes de `mv`, confirmación ya realizada, permisos inseguros, symlink de diario, preparación interrumpida, manifiesto corrupto y archivo inesperado durante la limpieza.

## Riesgos y trabajo pendiente

1. **Durabilidad ante corte de energía:** `mv` atómico no implica persistencia. Falta diseñar `fsync` para contenido y directorios, o limitar explícitamente el contrato de recuperación a fallas de proceso.
2. **Residuos de staging y completed:** una interrupción puede dejar archivos privados `.managed-prepare.*` o `.managed-completed.*`. Se necesita un procedimiento idempotente y seguro de inspección/limpieza, con protección frente a symlinks y estados ambiguos.
3. **Recuperación interrumpida:** ampliar las pruebas para cortes dentro de `bosh_managed_txn_recover()` y durante el retiro de diarios.
4. **Concurrencia y TOCTOU:** verificar la cobertura de locking en todos los puntos de entrada; revisar cambios externos entre comprobación de hash y publicación.
5. **Propiedad/identidad de rutas:** incorporar revisión de UID, padres simbólicos, rutas con traversal, hashes corruptos, formato de diario y permisos no canónicos; no basarse solo en permisos de modo.
6. **Flujos independientes:** `install_anime_images()` y `integrate_zsh()` tienen protocolos de publicación diferentes; no se benefician automáticamente del diario de archivos gestionados.
7. **Otros hallazgos de auditoría:** revisar la ejecución privilegiada de `uninstall.sh`, validaciones de padres y consistencia de desinstalación (separados de H1).

## Criterio de integración

Mantener [PR #4](https://github.com/terrible/bosh-terminal/pull/4) **en borrador** y [issue #3](https://github.com/terrible/bosh-terminal/issues/3) **abierto** hasta completar revisión de seguridad y pruebas ampliadas. No fusionar en `main` ni usarlo como base para publicar el instalador online.

La CI verde demuestra los comportamientos probados, **no una garantía general de crash-consistency**.
