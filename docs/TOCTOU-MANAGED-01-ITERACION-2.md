# TOCTOU-MANAGED-01 — Segunda iteración

Base de comparación: árbol `81d2608f27e341f83597b307668ccf9ebc9ad2ad`,
correspondiente a la primera iteración aplicada localmente sobre
`fa956b155dec0962bb13c75913d4cbd5ebd13c3c`.

## Riesgos corregidos

| Riesgo | Cambio y verificación |
| --- | --- |
| Candidato privado completo sin registro H1 definitivo | La preparación escribe `candidate` antes de copiar. Registra destino, dispositivo e inodo del directorio y del candidato, y SHA-256 esperado. Si el registro definitivo falta o está incompleto, se retira únicamente un candidato de un solo enlace y con identidad comprobada cuyo contenido esté vacío o coincida con el hash esperado. Las pruebas cortan el proceso antes y después de la copia y durante la recolección. |
| La preparación perdía su asociación con un candidato ambiguo | Un archivo parcial, una identidad que no coincide o un enlace inesperado mantienen tanto el diario como el directorio privado. El reintento devuelve error y permite inspección. Si el candidato y su directorio ya se retiraron en una recolección interrumpida, se completa la limpieza del diario. |
| Conflicto H1 v2 después de publicar el manifiesto | Cuando se comprueba que el manifiesto nuevo está publicado y el estado del destino o del directorio privado diverge, H1 guarda `conflict` en el diario pendiente o completado. El marcador impide la recuperación automática aunque una escritura posterior vuelva a hacer coincidir los bytes. Se conservan el manifiesto y ambas entradas. |
| Manifiesto activo corrupto o enlazado | La recuperación rechaza un manifiesto corrupto, simbólico o con múltiples enlaces. Preserva el diario y el archivo para inspección. Si se restaura el manifiesto válido y el diario carece de marcador de conflicto, se puede reintentar la recuperación. |
| Incompatibilidad detectada tarde | Antes del respaldo y del diario, un reemplazo valida que `mv` provenga de GNU coreutils 9.5 o posterior, compara el dispositivo del destino con su padre y ejecuta un intercambio sin copia con dos archivos vacíos privados. Se comprueba que ambos inodos hayan intercambiado sus posiciones. Una primera creación sigue usando un enlace exclusivo y no necesita esta comprobación. |
| Cobertura H1 perdida en Ubuntu | El workflow fija `ubuntu-26.04` y selecciona herramientas de `gnu-coreutils` únicamente en el PATH de los pasos del job. Reincorpora H1, TOCTOU y la prueba de artefactos. Arch conserva las regresiones dirigidas y la suite completa. [Imagen de GitHub Actions](https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2604-Readme.md) · [Paquete GNU de Ubuntu](https://packages.ubuntu.com/en/resolute/gnu-coreutils) · [Rutas de sus binarios](https://packages.ubuntu.com/en/resolute/amd64/gnu-coreutils/filelist) |

Se mantienen los formatos H1 v1 y v2 y el formato del manifiesto. Los
ficheros `candidate` y `conflict` son adiciones al diario. Para recuperar
un diario que los contenga, usar esta revisión del instalador o del
desinstalador.

## Límites y recuperación manual

- Una caída entre la creación del directorio privado y la escritura del
  comprobante puede dejar una preparación sin identidad verificable. Se
  conserva junto al directorio privado. Esta regla también se aplica a
  huérfanos de la primera iteración que no tengan registro completo.
  Un candidato con bytes parciales requiere inspección, porque el
  recuperador no puede distinguir una copia incompleta de una edición.
- La prueba de intercambio anticipa incompatibilidades con el sistema de
  archivos para cada reemplazo. El intercambio real aún puede fallar por
  permisos específicos o un cambio concurrente. Un bind mount de la
  entrada activa puede tener el mismo número de dispositivo que su
  directorio y aun así rechazar el intercambio real.
  Un `SIGKILL` durante el sondeo puede dejar un directorio
  `.bosh-exchange-probe.*` con archivos sintéticos. Inspeccionarlo antes
  de retirarlo de forma manual.
- El marcador registra un conflicto observado mientras el manifiesto
  publicado aún es verificable. Una interrupción antes de grabar el
  marcador, escrituras que se revierten entre verificaciones y cambios
  después de finalizar el diario pueden quedar fuera de la detección.
  El inodo desplazado permanece accesible para revisar escrituras tardías.
- Si aparece un conflicto o una preparación ambigua, detener las
  operaciones de Bosh y cerrar los procesos que puedan seguir
  escribiendo. Copiar a una ubicación privada el diario completo,
  incluida su marca o comprobante, el destino, el directorio privado,
  el manifiesto y los respaldos pertinentes. Comparar los contenidos y
  verificar qué generación corresponde al manifiesto activo. Tras
  conciliar los datos, archivar íntegro el diario fuera de los patrones
  activos de H1. Retirar solo el marcador permitiría reintentar sin
  conservar el motivo del bloqueo.
- Las pruebas cubren interrupciones de proceso y Home/XDG temporales.
  Persiste la limitación de durabilidad ante cortes de energía y de
  identidad de dispositivo tras remontajes. El intercambio y las
  comprobaciones siguen siendo operaciones separadas. Las rutas de
  anime, `~/.zshrc` y las mutaciones propias del desinstalador tienen
  ventanas de concurrencia independientes.

Para los estados de recuperación, compatibilidad y copia de evidencias,
véase [la guía de la primera iteración](TOCTOU-MANAGED-01.md).
