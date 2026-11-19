# Bosh Terminal — Auditoría de respaldos y temporales abandonados

**Fecha:** 18 de noviembre de 2026 (Chile)  
**Rama:** `fix/h1-transaction-recovery` · **PR:** [#4 (Draft)](https://github.com/terrible/bosh-terminal/pull/4)  
**Alcance:** archivos efímeros de clonación Oh My Zsh y recursos anime; **no incluye ni elimina los respaldos permanentes** de `$BOSH_BACKUP`.

## Objetivo y política de seguridad

Una terminación por `SIGKILL` impide ejecutar los traps de Bash y hace que se pierda el registro en memoria `BOSH_TEMP_PATHS`/`BOSH_TEMP_TYPES`. No es seguro interpretar cualquier ruta con un prefijo Bosh como propiedad del instalador: un usuario puede haber editado, sustituido, enlazado o reutilizado esos archivos tras la interrupción.

La auditoría inicial **no ejecuta borrado automático**, ni `chmod`, ni mueve archivos. El inventario informa candidatos; un nombre esperado no demuestra procedencia. Cualquier eliminación futura exige un registro de identidad durable y validación independiente del destino, contenido, permisos, propietario y enlaces, bajo el bloqueo correspondiente.

## Hallazgos confirmados en el código

| Categoría | Rutas observadas | Riesgo |
| --- | --- | --- |
| Clonación temporal de Oh My Zsh | `$HOME/.oh-my-zsh.bosh-tmp.XXXXXX/repo` | Una caída antes de publicar `~/.oh-my-zsh` puede dejar una clonación privada sin una ruta exacta registrada de forma durable |
| Rollback anterior de imagen anime | `$XDG_DATA_HOME/fastfetch/anime/*.png.bosh-rollback.XXXXXX` | Conserva la versión anterior, potencialmente necesaria tras un fallo; no se debe borrar por prefijo |
| Imagen temporal candidata | `*.png.bosh-tmp.XXXXXX` | Puede quedar tras un corte y corresponder a contenido no publicado |
| Staging para restauración de rollback | `*.png.bosh-restore.XXXXXX` | Puede quedar si se interrumpe una restauración |
| Backups permanentes `$BOSH_BACKUP` | Ruta versionada y respaldada | **No** son basura ni deben incluirse en una limpieza de temporales |

### Hallazgo de permisos en snapshots — corregido experimentalmente

Anteriormente, `install_anime_images()` utilizaba `cp -p` para poblar un rollback creado con `mktemp`; así podía copiar también los permisos `0644` del archivo original. **En la rama H1 esto se sustituyó por una copia sin `-p` sobre el archivo privado `0600`, con comprobación explícita del modo antes de utilizar el snapshot.**

El modo de la imagen original se mantiene independiente del snapshot. `bosh_restore_rollback_file()` recibe ese modo y lo aplica al destino después del reemplazo atómico, verificando el resultado antes de limpiar el rollback. Los nuevos diarios anime conservan `previous_mode` como octavo campo; la recuperación sigue aceptando diarios antiguos de siete campos.

**Un corte justo después del `mv` de restauración y antes de `chmod` puede dejar el destino temporalmente en `0600`.** Si el contenido y el manifiesto coinciden con la versión previa, pero el modo difiere, la recuperación de un diario nuevo rechaza la finalización automática y conserva el diario y el snapshot para inspección. No modifica un permiso que podría haber cambiado el usuario.

**Hallazgo independiente:** la imagen candidata `*.bosh-tmp.*` sigue usando `cp -p` para mantener los permisos del recurso publicado. Una interrupción puede dejar un candidato `0644`; la auditoría lo informa como `WARNING`. Esta etapa no cambia ese protocolo de publicación ni elimina residuos por nombre.

## Actualización de alcance — candidata integral (19-11-2026)

**Histórico:** los hallazgos anteriores describen la implementación H1 original. No deben confundirse con el estado del código de `integration/bosh-terminal-candidate` (PR #11).

- El candidato anime se prepara en un **directorio privado de staging `0700`**. Aunque `cp -p` preserve el modo interno del recurso, la ruta queda protegida por el directorio. La publicación verifica identidad del directorio y del candidato, número de enlaces `1` y hash.
- La regresión de la candidata incluye pruebas de staging privado, hardlinks, rollback y journaling; GitHub Actions de PR #11: [push PASS](https://github.com/terrible/bosh-terminal/actions/runs/44471564440) y [pull request PASS](https://github.com/terrible/bosh-terminal/actions/runs/44471613661).
- **Sin resolver:** identificación y tratamiento de staging legado, residuos de clonaciones OMZ y respaldos potencialmente reutilizados o modificados por terceros. Un prefijo de nombre nunca autoriza borrar. Permanece pendiente la auditoría de carreras externas y los límites frente a pérdida de energía.
- Esta actualización **no sustituye** la política original de herramienta de inventario en solo lectura ni concede autorización de limpieza automática.

## Herramienta añadida — solo lectura

`scripts/audit-temp-artifacts.sh` comprueba exclusivamente los patrones documentados en `HOME` y `XDG_DATA_HOME`. Usa `stat` y `sha256sum`; no evalúa diarios ni sigue symlinks. Comprueba:

- Ruta raíz y componentes padres sin symlink ni `..`.
- Nombre y sufijo temporal de seis caracteres.
- Tipo (directorio de clonación o archivo regular), UID, modo; número de enlaces para archivos.
- Hash SHA-256 de snapshots regulares privados, únicamente para identificación manual.

Los resultados usan categorías:

- `REVIEW`: forma y metadatos plausibles, **propiedad no verificada**.
- `WARNING`: permisos potencialmente expuestos o metadatos/hash ilegibles.
- `UNSAFE`: symlink, hardlink, propietario/tipo inesperado, formato inválido o ruta insegura.

El código de salida es **0** cuando no hay `WARNING`/`UNSAFE`, aunque existan `REVIEW`, y **2** cuando detecta alguno. Un resultado `REVIEW` **no autoriza eliminación**.

### Ejecución voluntaria tras una versión aprobada

```bash
bash scripts/audit-temp-artifacts.sh
```

No necesita `sudo`. Actualmente se encuentra solo en la rama de desarrollo H1, no en `main`; no debe ejecutarse sobre el sistema real como si fuera una herramienta publicada hasta completar la revisión.

## Pruebas

`tests/test-temp-artifacts.sh` crea `HOME` y `XDG_DATA_HOME` aislados. Los escenarios incluyen: directorio vacío, clonación privada, rollback privado con hash, staging temporal/restauración, modo `0644`, symlink, hardlink, nombre inesperado, clonación simbólica, permisos de directorio no privados, symlink en un padre XDG, rechazo de parámetros destructivos, `SIGKILL` real durante publicación Oh My Zsh y actualización anime interrumpida con rollback residual.

La CI comprueba sintaxis y ShellCheck del auditor y ejecuta estas pruebas sin `sudo` ni modificaciones del `HOME` real. **[Ejecución #44447701673](https://github.com/terrible/bosh-terminal/actions/runs/44447701673): 14/14 escenarios del auditor PASS, 8/8 regresiones de permisos y diario de rollback anime PASS, suite Arch 17/17 módulos PASS y 2/2 jobs PASS.**

## Remediación y trabajo pendiente

1. Crear un identificador durable de operación antes de publicar snapshots, y registrar su ruta exacta, tipo, hash y estado (sin depender del patrón de nombre).
2. Mantener snapshots recuperables mientras exista una operación incompleta y verificar el estado antes de limpiarlos.
3. Diseñar una recolección sin seguimiento de symlinks, sin borrado recursivo a ciegas y segura frente a cambios concurrentes.
4. **Implementado y probado:** rollback anime `0600` independiente del modo original, restauración verificable `0600`/`0640`/`0644`, y metadatos originales durables en el diario; los estados ambiguos se preservan.
5. Probar más fallos entre todas las transiciones de staging/journal/manifest/cleanup y reintentos idempotentes; aún faltan errores de E/S y cortes de energía.
6. Documentar un procedimiento de cuarentena **manual** con respaldos verificables; no ejecutar limpiezas sobre archivos personales automáticamente.
7. Revisar la exposición de candidatos `.bosh-tmp.*` con modo heredado por `cp -p`, sin perder los permisos finales ni el contrato de recuperación.

**Estado:** se incorpora una herramienta de diagnóstico y cobertura de regresión. La limpieza segura automática **permanece bloqueada** hasta contar con identidad/procedencia durable, pruebas ampliadas y revisión de seguridad. H1 no está cerrado; no autoriza merge ni release.
