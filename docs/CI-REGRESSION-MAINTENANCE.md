# Bosh Terminal — mantenimiento y seguridad de CI

**Estado:** procedimiento para revisar las validaciones de la candidata. No equivale a aprobación de merge/release.
**Revisión inicial:** 2026-11-19 (Chile).

## Workflow

El workflow único es `.github/workflows/h1-regression.yml`:

- `push` a `main`, `integration/bosh-terminal-candidate` y ramas `ci/**`; `pull_request` contra `main` o la candidata; ejecución manual con `workflow_dispatch`.
- Permiso global `contents: read`; `checkout` deshabilita `persist-credentials`; no usa secretos del repositorio.
- `concurrency` cancela ejecuciones obsoletas de la misma referencia; jobs con límites de 15 y 20 minutos.
- Ubuntu: Bash, ShellCheck y regresiones H1; contenedor Arch Linux: sintaxis, ShellCheck y suite integral, usando `bosh-ci` no privilegiado y `setsid -w` para carecer de TTY.

## Referencias fijadas y procedencia

| Componente | Referencia | Verificación |
|---|---|---|
| `actions/checkout` | `3d3c42e5aac5ba805825da76410c181273ba90b1` (`v7.0.1`) | `https://api.github.com/repos/actions/checkout/git/ref/tags/v7.0.1` |
| Contenedor oficial Arch | `archlinux:base-20261108.0.623074@sha256:d4594bb2300cba11f41c2f27923eb56f63d9988909c402f9c95517d1e362c899` | Docker Hub: índice de imagen de `library/archlinux` `base-20261108.0.623074` |
| Runner GitHub | `ubuntu-24.04` | Etiqueta de versión del runner (no hash inmutable) |

**Límite importante:** fijar la acción y el índice OCI evita desplazamientos de estas referencias, pero `apt-get update`, `pacman -Syu`, mirrors, paquetes, y actualizaciones del runner mantienen variabilidad. La imagen fijada puede contener paquetes antiguos antes de `pacman -Syu`. No presentar la CI como build bit a bit reproducible.

## Procedimiento para actualizar pines

1. Crear una nueva rama `ci/*` desde la candidata y conservar el commit anterior como referencia.
2. Verificar la etiqueta upstream de `actions/checkout` contra el SHA de commit completo en GitHub; no reemplazar el SHA por una etiqueta mutable.
3. Elegir una imagen oficial Arch con etiqueta de fecha y digest `sha256` **completo**, verificar que es el índice o manifiesto esperado para la arquitectura AMD64 y documentar su fuente. No confundir `archlinux/archlinux` con la imagen oficial `library/archlinux`.
4. Actualizar la referencia de `ubuntu-24.04` solamente tras comprobar compatibilidad y soporte.
5. Ejecutar la validación completa por `push` y `pull_request`: ambos trabajos deben finalizar PASS, y el nuevo caso de diario H1 real debe incluirse automáticamente mediante `tests/run-tests.sh`.
6. Registrar en el PR las URLs de ejecuciones, commits, módulos PASS/FAIL y cualquier regresión. No hacer merge si existen fallos, warnings no explicados o cambios inesperados en el diff.
7. Revisar los pines periódicamente por seguridad y compatibilidad. La inmutabilidad no reemplaza las actualizaciones de seguridad.

## Riesgos no resueltos por CI

- Condiciones de carrera, ataques TOCTOU, enlaces simbólicos y procesos externos al lock en rutas de archivos y diarios.
- Limpieza segura de residuos de clonación OMZ y snapshots de rollback anime ante interrupciones.
- Diferencia entre recuperación de `SIGKILL` y pérdida de energía (`fsync`).
- Política de consentimiento en desinstalación.
- Licencias/atribución de imágenes incluidas y revisión humana independiente.
- Ensayo de instalación, actualización y desinstalación en VM limpia con entornos soportados; no experimentar sobre el HOME real.

Ver `docs/RELEASE-READINESS-CHECKLIST.md` y PR #11. La aprobación de CI **no autoriza** merge ni release.
