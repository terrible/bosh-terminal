# Bosh Terminal — Auditoría de consistencia de Zsh

**Fecha:** 18 de noviembre de 2026 (hora local de Chile)  
**Rama:** `fix/h1-transaction-recovery`  
**Pull request:** [#4 — H1, borrador](https://github.com/terrible/bosh-terminal/pull/4)  
**Evidencia:** [GitHub Actions #44428391281](https://github.com/terrible/bosh-terminal/actions/runs/44428391281)

## Hallazgos

### Z1 — Manifiesto escrito antes de publicar `~/.zshrc`

El flujo anterior de `integrate_zsh()` escribía `zshrc_manifest` antes de reemplazar `~/.zshrc`. Una caída entre ambas operaciones dejaba una integración declarada, pero no instalada. Un nuevo intento podía tratarla como manifiesto huérfano y dificultar el diagnóstico de respaldo/estado.

**Corrección experimental:** `scripts/lib/zsh-transaction.sh` introduce un journal `zshrc_txn` publicado mediante `write_state` (archivo temporal + rename), antes de modificar el manifiesto o `~/.zshrc`.

En instalación, el registro contiene:

- Versión/componente y modo `created`, `appended` o `legacy_replaced`.
- SHA-256 del archivo original o indicador de ausencia.
- SHA-256 del candidato íntegro.
- SHA-256 del manifiesto previsto.

Tras una interrupción, la recuperación compara exactamente archivo/manifiesto con los hashes del journal, comprueba la asociación al respaldo original cuando existe el manifiesto, y realiza únicamente una de estas acciones:

| Estado | Recuperación |
| --- | --- |
| Original intacto + manifiesto prematuro | Archiva manifiesto y journal; no toca `~/.zshrc` |
| Original intacto + manifiesto todavía ausente | Archiva journal; permite reintentar |
| Archivo candidato + manifiesto esperado | Archiva journal; integración confirmada |
| Estado inesperado, symlink o contenido externo | Rechaza la recuperación y preserva evidencias |

Los respaldos originales se conservan. Los manifiestos interrumpidos se archivan en lugar de borrarse sin trazabilidad.

### Z2 — Desinstalación interrumpida antes del archivado del manifiesto

El desinstalador podía retirar el bloque Bosh o restaurar un `~/.zshrc` antiguo y quedar interrumpido antes de archivar `zshrc_manifest`.

**Corrección experimental:** se añade `zshrc_uninstall_txn`, registrado antes de cada mutación del archivo. La recuperación compara el hash anterior y el resultado de desinstalación, junto con el hash esperado del manifiesto; archiva el estado solo cuando la operación es verificable. Las modificaciones externas se preservan y bloquean la recuperación.

La recuperación se invoca tanto al instalar como al desinstalar, y el instalador principal la ejecuta antes de instalar dependencias, con el lock compartido.

## Evidencia de regresión

| Comprobación | Resultado |
| --- | --- |
| Recuperación de instalación Zsh | **9/9 PASS** |
| Recuperación de desinstalación Zsh | **8/8 PASS** |
| Suite completa en contenedor Arch Linux | **13/13 módulos PASS** |
| Sintaxis Bash y ShellCheck | PASS |
| GitHub Actions | 2/2 jobs PASS |

Se incluyen procesos terminados por `exit` y `SIGKILL`, los tres modos de integración, preservación de permisos y alias, modificaciones del usuario, journaling manipulados, reintentos idempotentes y cortes entre archivo/manifiesto.

**Los tests usan HOME aislado y scripts de prueba; no requieren ni modifican el `~/.zshrc` real del usuario.**

## Límites y revisión pendiente

1. **No certifica cortes de energía:** `write_state`, `mv` y `archive_state` usan renombrados atómicos, pero no incluyen `fsync` de datos/directorios. La garantía alcanzada se limita a los casos de caída de proceso comprobados.
2. **TOCTOU/concurrencia:** existe un lock de instalador/desinstalador, pero procesos externos del mismo UID podrían modificar archivos entre verificaciones y renombrados. Requiere revisión adicional.
3. **Journals previos a la corrección:** si una instalación se interrumpió antes de existir estos diarios, no se debe reconstruir un respaldo ambiguo automáticamente. Mantener preservación/manual review.
4. **Interrupción durante el archivado:** se probaron puntos de corte relevantes, pero no todos los errores posibles de disco, permisos o corrupción accidental.
5. **Oh My Zsh:** las operaciones y estados propios de Oh My Zsh no forman parte de estos journals. Este informe no valida por completo ese componente.
6. **Anime/Fastfetch:** instalación y desinstalación de imágenes usa otro protocolo, todavía pendiente de auditoría específica.
7. **No apto aún para release:** H1 permanece abierto; PR #4 en borrador y `main` sin fusionar.

## Próxima acción

Auditar por separado el reemplazo de imágenes anime y el estado de Oh My Zsh. Realizar una revisión de seguridad final antes de considerar el merge de H1/H2 y la actualización del commit fijado por el instalador online.
