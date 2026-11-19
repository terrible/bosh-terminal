# Bosh Terminal — Criterios para aprobar el instalador automático

**Estado:** propuesta de checklist, **sin autorización de merge ni release**.  
**Fecha de revisión:** 19 de noviembre de 2026 (Chile).  
**Base de revisión:** PR [#2 (H2)](https://github.com/terrible/bosh-terminal/pull/2), [#4 (H1)](https://github.com/terrible/bosh-terminal/pull/4), [#6 (staging anime)](https://github.com/terrible/bosh-terminal/pull/6), [#8 (consentimiento)](https://github.com/terrible/bosh-terminal/pull/8), [#10 (diario H1 real)](https://github.com/terrible/bosh-terminal/pull/10), [#11 (candidata)](https://github.com/terrible/bosh-terminal/pull/11) y [#1 (instalador online)](https://github.com/terrible/bosh-terminal/pull/1).

## Evidencia reunida, no equivalente a aprobación de release

- [x] Tests del lanzador online (aislados): 14/14 PASS en Ubuntu y Arch; comprobación de descarga por commit y SHA sin ejecutar el contenido (CI #44410597727).
- [x] Regresiones H1 de archivos gestionados: 19/19 PASS (CI #44400090199).
- [x] Regresiones de instalación Zsh: 9/9 PASS (CI #44428676576).
- [x] Regresiones de desinstalación Zsh: 8/8 PASS (CI #44428676576).
- [x] Regresiones Oh My Zsh: 8/8 PASS (CI #44439239909).
- [x] Regresiones anime: 7/7 PASS (CI #44439239909).
- [x] Suite histórica en contenedor Arch: 15/15 módulos PASS (CI #44439239909); ver resultados actuales de 19 módulos abajo.
- [x] Bash syntax y ShellCheck PASS en las ramas probadas.
- [x] Auditoría de residuos temporal **solo lectura**, con pruebas de `SIGKILL` reales sobre clonación OMZ y rollback anime: **14/14 PASS**, suite Arch **16/16 módulos PASS** ([CI #44445178671](https://github.com/terrible/bosh-terminal/actions/runs/44445178671)); ver [reporte](TEMP-ARTIFACTS-AUDIT.md).
- [x] Protección del modo de snapshots anime: **8/8** pruebas (incluidos `SIGKILL`, diarios históricos y restauración de modos), **17/17** módulos del proyecto en Arch, Bash/ShellCheck y **2/2** jobs aprobados ([CI #44447701673](https://github.com/terrible/bosh-terminal/actions/runs/44447701673)).
- [x] Consentimiento interactivo obligatorio antes de lock y recuperación en `install.sh`: 6/6 pruebas específicas, E2E 4/4 y desinstalación 19/19 reportadas en EndeavourOS ([PR #8](https://github.com/terrible/bosh-terminal/pull/8)).
- [x] Diario H1 **auténtico**: rechazo y ausencia de TTY conservan diario, destino, respaldo y metadatos; 1/1 PASS local; suite integral **19/19 módulos PASS, 0 fallidos** sobre `5d8c4f0` en worktree aislado ([PR #10](https://github.com/terrible/bosh-terminal/pull/10)).
- [x] Candidata `fa956b1`: Bash/ShellCheck/H1 Ubuntu y suite Arch sin TTY, **2/2 trabajos PASS** en [push](https://github.com/terrible/bosh-terminal/actions/runs/44471564440) y **2/2 PASS** en [pull request](https://github.com/terrible/bosh-terminal/actions/runs/44471613661).
- [x] Validación inicial de CI endurecida con `actions/checkout` v4.2.2 (evidencia histórica, **no pin final**) e imagen Arch por digest: [push #44472535769](https://github.com/terrible/bosh-terminal/actions/runs/44472535769) y [PR #44472606853](https://github.com/terrible/bosh-terminal/actions/runs/44472606853), ambos **2/2 trabajos PASS**.
- [x] `actions/checkout` v7.0.1 fijado al commit `3d3c42e5aac5ba805825da76410c181273ba90b1`, imagen Arch por digest y `ubuntu-24.04`: **2/2 trabajos PASS** en [push #44473088712](https://github.com/terrible/bosh-terminal/actions/runs/44473088712) y [PR #44473096492](https://github.com/terrible/bosh-terminal/actions/runs/44473096492). Ver [mantenimiento de CI](CI-REGRESSION-MAINTENANCE.md).


## Bloqueos pendientes antes de una versión pública

- [ ] Auditar las condiciones de carrera y los enlaces simbólicos en rutas involucradas en diarios y renombrados, incluyendo procesos externos al lock.
- [ ] Definir un procedimiento seguro para identificar y limpiar snapshots de rollback anime y carpetas de clonación Oh My Zsh que permanezcan tras `SIGKILL`, sin borrar datos personales desconocidos.
- [x] Snapshots anime de rollback `0600` y recuperación de permisos originales `0600`/`0640`/`0644`, con modo persistente en diario compatible con registros anteriores; probado en CI #44447701673.
- [x] Endurecimiento del staging de candidatos anime `*.bosh-tmp.*`: directorio privado `0700`, validación de identidad y contador de enlaces, preservación de originales y reversión segura. Implementado en [PR #6](https://github.com/terrible/bosh-terminal/pull/6), con regresiones de staging y CI de la candidata aprobadas. No equivale a una auditoría completa frente a procesos externos.
- [ ] Definir el alcance de durabilidad frente a `SIGKILL` versus pérdida de energía; si se promete recuperación ante apagón, implementar y ensayar `fsync` de archivos y directorios.
- [ ] Revisar la política de versión de Oh My Zsh upstream y la coherencia de commit/hash de árbol en repositorios preexistentes.
- [ ] Confirmar colección anime distribuible, atribución y licencias de recursos gráficos.
- [ ] Obtener revisión humana o independiente de seguridad para H1 y H2; actualizar documentación de riesgos.
- [ ] Autorizar y realizar merges ordenados: H2, H1 y finalmente el lanzador online; resolver conflictos y verificar el código resultante.
- [ ] Actualizar `PINNED_COMMIT` del lanzador únicamente a una revisión aprobada de `main`. En la auditoría del 19-11-2026, `main` seguía en `3fc14e53813bab8d31e16c57c716695549ab9d72`, previo a H1/H2; volver a comprobar antes de cualquier release.
- [ ] Probar `curl | bash` con descarga real, interacción por `/dev/tty`, instalación, reinstalación y desinstalación en VM/entorno Arch limpio con usuario no privilegiado.
- [ ] Repetir toda la suite (incluidos H2, H1, OMZ, anime y online) contra el commit final integrado y verificar `git diff --check`, `bash -n`, ShellCheck y errores de la CI.
- [ ] Revisar instrucciones de backup/restauración, efectos de `pacman -Syu`, README ES/EN, alcance de distribución y versionado.
- [ ] Establecer y documentar política de consentimiento para `uninstall.sh`: actualmente obtiene lock e invoca recuperación sin una pregunta interactiva equivalente; no está demostrado que el flujo de desinstalación requiera la misma política que el instalador.
- [ ] Mantener política de actualización de dependencias CI: los commits de acciones y digest del contenedor se fijan, pero paquetes `apt`/`pacman -Syu`, mirror y runner aún pueden cambiar con el tiempo; revisar periódicamente [procedimiento de mantenimiento](CI-REGRESSION-MAINTENANCE.md).

- [ ] Requerir autorización explícita para publicar una release y anunciar el comando de instalación.

## Reglas de seguridad

1. Los resultados verdes son evidencias del entorno y escenarios probados, no certificación de ausencia de vulnerabilidades.
2. No ejecutar instalaciones experimentales en las configuraciones reales del propietario ni sobrescribir dotfiles de usuario.
3. No hacer merges, cambios en `main` ni nuevas releases sin aprobación explícita.
4. Ante estado no reconocido, **conservar el archivo, manifest y diario para inspección**.
