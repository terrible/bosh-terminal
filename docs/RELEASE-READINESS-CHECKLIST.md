# Bosh Terminal — Criterios para aprobar el instalador automático

**Estado:** propuesta de checklist, **sin autorización de merge ni release**.  
**Fecha:** 18 de noviembre de 2026 (Chile).  
**Base de revisión:** PR [#2 (H2)](https://github.com/terrible/bosh-terminal/pull/2), [#4 (H1)](https://github.com/terrible/bosh-terminal/pull/4), [#1 (instalador online)](https://github.com/terrible/bosh-terminal/pull/1).

## Evidencia reunida, no equivalente a aprobación de release

- [x] Tests del lanzador online (aislados): 14/14 PASS en Ubuntu y Arch; comprobación de descarga por commit y SHA sin ejecutar el contenido (CI #44410597727).
- [x] Regresiones H1 de archivos gestionados: 19/19 PASS (CI #44400090199).
- [x] Regresiones de instalación Zsh: 9/9 PASS (CI #44428676576).
- [x] Regresiones de desinstalación Zsh: 8/8 PASS (CI #44428676576).
- [x] Regresiones Oh My Zsh: 8/8 PASS (CI #44439239909).
- [x] Regresiones anime: 7/7 PASS (CI #44439239909).
- [x] Suite actual completa en contenedor Arch: 15/15 módulos PASS (CI #44439239909).
- [x] Bash syntax y ShellCheck PASS en las ramas probadas.
- [x] Auditoría de residuos temporal **solo lectura**, con pruebas de `SIGKILL` reales sobre clonación OMZ y rollback anime: **14/14 PASS**, suite Arch **16/16 módulos PASS** ([CI #44445178671](https://github.com/terrible/bosh-terminal/actions/runs/44445178671)); ver [reporte](TEMP-ARTIFACTS-AUDIT.md).

## Bloqueos pendientes antes de una versión pública

- [ ] Auditar las condiciones de carrera y los enlaces simbólicos en rutas involucradas en diarios y renombrados, incluyendo procesos externos al lock.
- [ ] Definir un procedimiento seguro para identificar y limpiar snapshots de rollback anime y carpetas de clonación Oh My Zsh que permanezcan tras `SIGKILL`, sin borrar datos personales desconocidos.
- [ ] Evitar que snapshots de rollback retengan permisos amplios heredados por `cp -p` (modo `0644` observado en test real), conservando el modo original cuando sea necesaria una restauración.
- [ ] Definir el alcance de durabilidad frente a `SIGKILL` versus pérdida de energía; si se promete recuperación ante apagón, implementar y ensayar `fsync` de archivos y directorios.
- [ ] Revisar la política de versión de Oh My Zsh upstream y la coherencia de commit/hash de árbol en repositorios preexistentes.
- [ ] Confirmar colección anime distribuible, atribución y licencias de recursos gráficos.
- [ ] Obtener revisión humana o independiente de seguridad para H1 y H2; actualizar documentación de riesgos.
- [ ] Autorizar y realizar merges ordenados: H2, H1 y finalmente el lanzador online; resolver conflictos y verificar el código resultante.
- [ ] Actualizar `PINNED_COMMIT` del lanzador únicamente a una revisión aprobada de `main`. Actualmente apunta a `3fc14e53813bab8d31e16c57c716695549ab9d72`, previo a H1/H2.
- [ ] Probar `curl | bash` con descarga real, interacción por `/dev/tty`, instalación, reinstalación y desinstalación en VM/entorno Arch limpio con usuario no privilegiado.
- [ ] Repetir toda la suite (incluidos H2, H1, OMZ, anime y online) contra el commit final integrado y verificar `git diff --check`, `bash -n`, ShellCheck y errores de la CI.
- [ ] Revisar instrucciones de backup/restauración, efectos de `pacman -Syu`, README ES/EN, alcance de distribución y versionado.
- [ ] Requerir autorización explícita para publicar una release y anunciar el comando de instalación.

## Reglas de seguridad

1. Los resultados verdes son evidencias del entorno y escenarios probados, no certificación de ausencia de vulnerabilidades.
2. No ejecutar instalaciones experimentales en las configuraciones reales del propietario ni sobrescribir dotfiles de usuario.
3. No hacer merges, cambios en `main` ni nuevas releases sin aprobación explícita.
4. Ante estado no reconocido, **conservar el archivo, manifest y diario para inspección**.
