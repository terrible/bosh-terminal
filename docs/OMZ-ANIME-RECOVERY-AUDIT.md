# Bosh Terminal — Auditoría de recuperación de Oh My Zsh e imágenes anime

**Fecha:** 18 de noviembre de 2026 (Chile)  
**Rama:** `fix/h1-transaction-recovery`  
**Pull request:** [#4 — H1, borrador](https://github.com/terrible/bosh-terminal/pull/4)  
**CI aprobada:** [GitHub Actions #44439239909](https://github.com/terrible/bosh-terminal/actions/runs/44439239909)

> **Alcance:** pruebas de consistencia frente a interrupciones del proceso. No son ensayos de desconexión eléctrica, corrupción de disco ni seguridad frente a procesos maliciosos del mismo UID.

## O1 — Oh My Zsh: manifiesto de propiedad antes de publicar el repositorio

### Hallazgo

`install_oh_my_zsh()` escribía `oh_my_zsh_manifest` antes de renombrar la carpeta clonada a `~/.oh-my-zsh`. Un `SIGKILL` entre ambos pasos dejaba un manifiesto que declaraba propiedad de un directorio todavía inexistente.

### Implementación experimental

- Añadido `scripts/lib/omz-transaction.sh` con `oh_my_zsh_txn` como diario `write_state` previo al manifiesto y al renombrado.
- El diario almacena commit, hash del árbol de archivos de la clonación y hash exacto del manifiesto esperado.
- Instalador y desinstalador examinan el diario bajo el bloqueo común, antes de otras operaciones.
- Si el destino sigue ausente, el manifiesto prematuro y el diario se archivan; no se inventa ni adopta ninguna instalación.
- Si ya se publicó el destino, se validan Git remoto, commit, árbol de archivos y manifiesto antes de archivar el diario.
- Un repositorio personalizado, un remoto alterado, un árbol modificado, un symlink o un diario inválido bloquean la recuperación y son preservados.

**Evidencia:** `tests/test-omz-recovery.sh` = **8/8 PASS**. Incluye `exit`, `SIGKILL`, fallo del manifiesto, interrupción al finalizar, modificación de plugin, alteración del remoto, datos de diario malformados y symlink.

## A1 — Anime: imagen reemplazada antes de registrar su propietario/hash

### Hallazgo

`install_anime_images()` reemplazaba una imagen `.png` antes de escribir su estado `anime_<sha256(filename)>`. Una interrupción podía dejar imagen nueva y registro antiguo o ausente. Una ejecución posterior no podía atribuir de forma inequívoca el reemplazo.

### Implementación experimental

- Añadido `scripts/lib/anime-transaction.sh` con un diario por nombre de imagen `anime_<sha256(filename)>_txn`.
- El diario contiene filename en Base64, SHA-256 anterior/nuevo de imagen y SHA-256 anterior/nuevo del manifiesto.
- Antes de interpretar un manifiesto, el instalador puede conciliar el destino por hash y registrar el estado nuevo exclusivamente cuando coincide con el candidato verificado.
- La desinstalación examina todos los diarios pendientes, incluyendo imágenes retiradas de una futura colección, antes de procesar propiedad y eliminación.
- Si la imagen continúa en estado anterior, el diario se archiva sin cambiarla. Si hay edición externa, symlink o estado incongruente, la operación se detiene y conserva los archivos.
- Una imagen personal preexistente sin manifiesto de propiedad válido **no se adquiere ni reemplaza**.

**Evidencia:** `tests/test-anime-recovery.sh` = **7/7 PASS**. Incluye primera instalación abortada, actualización con `SIGKILL`, corte previo al `mv`, edición externa, imagen personal, diario simbólico y desinstalación con operación pendiente.

## Evidencias consolidadas

| Comprobación | Resultado |
| --- | --- |
| Nuevas regresiones de Oh My Zsh | **8/8 PASS** |
| Nuevas regresiones de imágenes anime | **7/7 PASS** |
| Recuperación Zsh y desinstalación Zsh (trabajo anterior) | **17/17 PASS** |
| Recuperación de archivos gestionados H1 (trabajo anterior) | **19/19 PASS** |
| Suite completa Arch Linux, usuario no privilegiado | **15/15 módulos PASS** |
| Sintaxis Bash, ShellCheck | PASS |
| GitHub Actions | **2/2 jobs PASS** |

Las pruebas de interrupción y las regresiones se ejecutan con `HOME` aislado. La clonación de Oh My Zsh se simula con un repositorio Git local de prueba; no se instala software en el equipo del propietario del proyecto.

## Riesgos pendientes y decisiones de seguridad

1. **Cortes de energía y durabilidad:** los renombrados atómicos y los diarios no bastan para garantizar persistencia sin `fsync` de archivos y directorios. Las pruebas realizadas demuestran recuperación de caídas de proceso para los escenarios cubiertos, no supervivencia a apagones.
2. **Residuos temporales después de `SIGKILL`:** una clonación Oh My Zsh interrumpida puede conservar `~/.oh-my-zsh.bosh-tmp.*` y una actualización anime puede conservar `*.bosh-rollback.*`. No se eliminan automáticamente por adivinación de nombres. Hace falta diseñar recolección segura por identidad/hashes para evitar pérdida accidental de archivos de usuario.
3. **Concurrencia/TOCTOU:** `flock` serializa los procesos de Bosh, pero no controla ediciones externas simultáneas realizadas por otro proceso del mismo usuario.
4. **Integridad de Oh My Zsh preexistente:** se preservan los repositorios locales y personalizaciones. La política histórica R-2 actualiza la referencia del commit en ciertos cambios de commit; se requiere revisión separada de la coherencia entre hash de árbol y commit para no debilitar la política aprobada.
5. **Reproducibilidad de terceros:** la clonación de Oh My Zsh usa la revisión upstream disponible al momento de instalar, no un commit fijo como el lanzador online. La política de versión fijada debe decidirse antes de una release reproducible.
6. **Auditoría de carrera y errores de E/S:** faltan inyecciones en todos los puntos de escritura/archivado, pruebas de modificaciones concurrentes y recuperación con insuficiencia de espacio/permisos.
7. **Instalador online:** el [PR #1](https://github.com/terrible/bosh-terminal/pull/1) todavía fija un commit anterior a H1/H2. No actualizarlo ni publicarlo hasta aprobar la integración y una instalación E2E de sistema limpio.
8. **Artefactos anime y licencias:** revisar el inventario final de recursos incluidos, licencias y README antes de distribuir la versión pública.

## Decisión

- Mantener el [PR #4](https://github.com/terrible/bosh-terminal/pull/4) en **Draft**, el [issue H1 #3](https://github.com/terrible/bosh-terminal/issues/3) **abierto** y `main` sin fusionar.
- Revisar residuos y condiciones de carrera, después coordinar la revisión de H2, H1 y el lanzador online.
- No ejecutar ninguna instalación real ni publicar una release sin validación y aprobación.
