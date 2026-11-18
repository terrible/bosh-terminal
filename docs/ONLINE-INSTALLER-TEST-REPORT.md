# Bosh Terminal — Informe de pruebas del instalador online

**Fecha:** 18 de noviembre de 2026  
**PR:** [#1 — instalador de un comando (Draft)](https://github.com/terrible/bosh-terminal/pull/1)  
**Rama:** `feature/one-command-installer`  
**Última ejecución verificada:** [GitHub Actions #44410331498](https://github.com/terrible/bosh-terminal/actions/runs/44410331498) — **3/3 jobs aprobados**

## Alcance

Se valida el lanzador `install-online.sh` de 49 líneas, separado del instalador principal `install.sh`. La batería de pruebas del lanzador utiliza un Git simulado y un instalador hijo simulado para reproducir errores **sin modificar configuraciones ni instalar paquetes de usuario**. Una prueba separada realiza exclusivamente la descarga real del commit fijado desde GitHub por HTTPS, comprueba su hash y **no ejecuta el contenido descargado**.

## Evidencia reproducible

| Verificación | Resultado |
| --- | --- |
| Pruebas aisladas del lanzador en Ubuntu | **14/14 PASS** |
| Pruebas aisladas del lanzador en Arch Linux | **14/14 PASS** |
| Suite completa de Bosh Terminal en contenedor Arch Linux | **10/10 módulos PASS** |
| Rechazo de ejecución como root (contenedor) | PASS |
| Bash `-n` + ShellCheck del lanzador y tests | PASS |
| Descarga real de GitHub por commit SHA y verificación de SHA | PASS |
| GitHub Actions | **3/3 jobs PASS** |

### Escenarios del lanzador

1. `--help` no dispara descargas.
2. Argumentos desconocidos son rechazados antes de descargar.
3. Falta de terminal de control (`/dev/tty`) bloquea la instalación.
4. Ausencia de `git` bloquea antes de crear archivos.
5. Lanzamiento mediante tubería (`cat | bash`, simulación del flujo `curl | bash`) con pseudoterminal, confirmación del usuario y ejecución posterior al chequeo de SHA.
6. Rechazo de confirmación por el usuario detiene el instalador.
7. Fallo de `git fetch`: el hijo no se ejecuta.
8. SHA distinto al fijado: el hijo no se ejecuta.
9. Fallo de `git rev-parse`: no se ejecuta.
10. Fallo de `git checkout`: no se ejecuta.
11. Falta de `install.sh` en checkout: no se ejecuta.
12. Falta de `scripts/lib/common.sh`: no se ejecuta.
13. Fallo del instalador hijo: se propaga el código de salida y limpia el directorio temporal.
14. Fallo de `git init`: detiene antes de `fetch` y preserva el archivo centinela.

El fixture comprueba además que la URL remota sea `https://github.com/terrible/bosh-terminal.git`, el SHA solicitado sea exactamente el fijado y `GIT_TERMINAL_PROMPT=0` impida prompts de autenticación durante `fetch`. La limpieza comprueba la ausencia de carpetas `bosh-terminal-online.*` y la conservación de un centinela en `TMPDIR`.

## Archivos añadidos

- `tests/online-fixture.sh` — simulador local hermético de Git e instalador hijo.
- `tests/test-install-online.sh` — 14 pruebas de aceptación y seguridad.
- `.github/workflows/online-installer.yml` — jobs Ubuntu, Arch Linux y descarga real por SHA.

## Límites y bloqueos antes de publicar

- **Pin obsoleto respecto de auditorías:** el lanzador sigue fijando `3fc14e53813bab8d31e16c57c716695549ab9d72`, un commit anterior a H2 y a la corrección experimental H1. No cambiar el pin hacia una rama aún sin revisar ni fusionar.
- **No hay instalación pública E2E completa:** el flujo `curl | bash` ha sido probado con un instalador hijo simulado; las dependencias reales y la configuración de usuario **no** se han aplicado por Internet en una máquina de prueba limpia.
- **H1 sigue abierto:** faltan garantías ante pérdida de energía, auditoría de carreras y flujos independientes de Zsh/imágenes anime.
- **H2 y H1 permanecen en PR separados** y sin integrar a `main`.
- Revisar el contrato de seguridad del canal de descarga, documentación y posible interacción con variables de entorno de Git antes de publicar.

**Decisión recomendada:** mantener el PR #1 en borrador, no fusionar en `main`, no anunciar el comando público y no publicar release todavía. Tras aprobar H1/H2, crear nuevo commit revisado, actualizar el pin, repetir los tres jobs y ejecutar un E2E limpio en Arch/EndeavourOS desechable.
