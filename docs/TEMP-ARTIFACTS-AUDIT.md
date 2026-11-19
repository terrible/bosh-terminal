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

El código de imágenes usa `cp -p` para crear el rollback sobre un archivo generado con `mktemp`. **`cp -p` conserva el modo de la imagen original**: si era `0644`, el respaldo temporal puede conservar también `0644`. Esto no implica que los datos originales fueran privados, pero sí prolonga la exposición de una copia que puede permanecer después de borrar la imagen publicada. Es una mejora de endurecimiento pendiente; **el auditor lo detecta, sin modificar permisos**.

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

La CI comprueba sintaxis y ShellCheck del auditor y ejecuta estas pruebas sin `sudo` ni modificaciones del `HOME` real. Consultar el historial de [GitHub Actions en la rama H1](https://github.com/terrible/bosh-terminal/actions/workflows/h1-regression.yml).

## Plan de remediación: aún no implementado

1. Crear un identificador durable de operación antes de publicar snapshots, y registrar su ruta exacta, tipo, hash y estado (sin depender del patrón de nombre).
2. Mantener snapshots recuperables mientras exista una operación incompleta y verificar el estado antes de limpiarlos.
3. Diseñar una recolección sin seguimiento de symlinks, sin borrado recursivo a ciegas y segura frente a cambios concurrentes.
4. Reconsiderar `cp -p` en los rollback anime para retener contenido en archivos `0600` y **restaurar posteriormente los permisos originales**; validar con tests de modos `0600`, `0640`, `0644`.
5. Probar fallos entre todas las transiciones de staging/journal/manifest/cleanup y reintentos idempotentes.
6. Documentar un procedimiento de cuarentena **manual** con respaldos verificables; no ejecutar limpiezas sobre archivos personales automáticamente.

**Estado:** se incorpora una herramienta de diagnóstico y cobertura de regresión. La limpieza segura automática **permanece bloqueada** hasta contar con identidad/procedencia durable, pruebas ampliadas y revisión de seguridad. H1 no está cerrado; no autoriza merge ni release.
