# Bosh Terminal — Criterios para aprobar el instalador automático

**Estado:** propuesta de checklist, **sin autorización de merge ni release**.  
**Fecha inicial:** 18 de noviembre de 2026 (Chile). **Última revisión de evidencia:** 19 de noviembre de 2026.  
**Base de revisión:** PR [#2 (H2)](https://github.com/terrible/bosh-terminal/pull/2), [#4 (H1)](https://github.com/terrible/bosh-terminal/pull/4), [#1 (instalador online)](https://github.com/terrible/bosh-terminal/pull/1), [#8 (consentimiento)](https://github.com/terrible/bosh-terminal/pull/8), [#10 (diario H1 auténtico)](https://github.com/terrible/bosh-terminal/pull/10) y [#11 (candidata integral)](https://github.com/terrible/bosh-terminal/pull/11).

## Evidencia reunida, no equivalente a aprobación de release

- [x] Tests del lanzador online (aislados): 14/14 PASS en Ubuntu y Arch; comprobación de descarga por commit y SHA sin ejecutar el contenido (CI #44410597727).
- [x] Regresiones H1 de archivos gestionados: 19/19 PASS (CI #44400090199).
- [x] Regresiones de instalación Zsh: 9/9 PASS (CI #44428676576).
- [x] Regresiones de desinstalación Zsh: 8/8 PASS (CI #44428676576).
- [x] Regresiones Oh My Zsh: 8/8 PASS (CI #44439239909).
- [x] Regresiones anime: 7/7 PASS (CI #44439239909).
- [x] Suite histórica completa en contenedor Arch: 15/15 módulos PASS (CI #44439239909).
- [x] Bash syntax y ShellCheck PASS en las ramas probadas.
- [x] Auditoría de residuos temporal **solo lectura**, con pruebas de `SIGKILL` reales sobre clonación OMZ y rollback anime: **14/14 PASS**, suite Arch **16/16 módulos PASS** ([CI #44445178671](https://github.com/terrible/bosh-terminal/actions/runs/44445178671)); ver [reporte](TEMP-ARTIFACTS-AUDIT.md).
- [x] Protección del modo de snapshots anime: **8/8** pruebas (incluidos `SIGKILL`, diarios históricos y restauración de modos), **17/17** módulos del proyecto en Arch, Bash/ShellCheck y **2/2** jobs aprobados ([CI #44447701673](https://github.com/terrible/bosh-terminal/actions/runs/44447701673)).

### Evidencia de la candidata integral (19-11-2026)

- [x] Consentimiento previo a bloqueo y recuperación: **6/6 PASS**; E2E **4/4 PASS**; desinstalación **19/19 PASS** en EndeavourOS, PR #8.
- [x] Diario H1 auténtico, no centinela: rechazo de consentimiento y ejecución sin TTY preservan diario, archivo destino, respaldos, hashes y metadatos (**1/1 PASS**); suite local integral **19/19 módulos PASS**, commit `5d8c4f0`, PR #10.
- [x] PR #10, CI push y PR: **2/2 ejecuciones PASS**, en Ubuntu (Bash/ShellCheck/H1) y Arch Linux (suite sin TTY).
- [x] Candidata del PR #11, commit `fa956b1`: CI por push [#44471564440](https://github.com/terrible/bosh-terminal/actions/runs/44471564440) y por pull request [#44471613661](https://github.com/terrible/bosh-terminal/actions/runs/44471613661), **ambas con 2/2 jobs PASS**; 74 commits ahead / 0 behind respecto de `main`.
- [x] Endurecimiento aplicado al staging temporal de candidatos anime: directorio `0700`, comprobación de identidad de directorio/archivo y protección contra hardlinks antes de publicación o limpieza. La **limpieza de residuos preexistentes/externos sigue pendiente**, no se autoriza borrado por patrón.
- [ ] Validar la rama de endurecimiento de CI/documentación mediante GitHub Actions y aprobar explícitamente cada riesgo residual antes de cualquier fusión o release.


## Bloqueos pendientes antes de una versión pública

- [ ] Auditar las condiciones de carrera y los enlaces simbólicos en rutas involucradas en diarios y renombrados, incluyendo procesos externos al lock.
- [ ] Definir un procedimiento seguro para identificar y limpiar snapshots de rollback anime y carpetas de clonación Oh My Zsh que permanezcan tras `SIGKILL`, sin borrar datos personales desconocidos.
- [x] Snapshots anime de rollback `0600` y recuperación de permisos originales `0600`/`0640`/`0644`, con modo persistente en diario compatible con registros anteriores; probado en CI #44447701673.
- [x] Endurecer el staging de **candidatos** anime con un directorio privado `0700`, validación de identidad y defensa de hardlinks, manteniendo los permisos finales del recurso. **El inventario, cuarentena y limpieza de residuos antiguos siguen abiertos** (ver punto anterior).
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

## CI y cadena de suministro (evaluación 19-11-2026)

- [x] El workflow ejecuta pruebas en PR hacia `main` y contempla `push` hacia `main` tras la integración (no se ha fusionado).
- [x] `actions/checkout` fijado al SHA completo verificado para `v4.2.2`; `ubuntu-24.04` elegido en lugar del alias `ubuntu-latest`.
- [ ] `archlinux:latest` permanece móvil: fijar y verificar un **digest de manifiesto** para la arquitectura utilizada, y planificar su actualización. No confundir digest de capa con digest de imagen.
- [ ] El contenedor ejecuta `pacman -Syu`: las versiones del repositorio Arch también cambian; evaluar snapshots fechados/mirror y registrar versiones instaladas.
- [ ] Verificar y revisar el workflow endurecido de esta rama en CI antes de considerar la configuración lista.

## Reglas de seguridad

1. Los resultados verdes son evidencias del entorno y escenarios probados, no certificación de ausencia de vulnerabilidades.
2. No ejecutar instalaciones experimentales en las configuraciones reales del propietario ni sobrescribir dotfiles de usuario.
3. No hacer merges, cambios en `main` ni nuevas releases sin aprobación explícita.
4. Ante estado no reconocido, **conservar el archivo, manifest y diario para inspección**.
