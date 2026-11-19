# TOCTOU-MANAGED-01

Base `fa956b155dec0962bb13c75913d4cbd5ebd13c3c`.

La [segunda iteración](TOCTOU-MANAGED-01-ITERACION-2.md) actualiza la
recolección, la recuperación posmanifiesto y la cobertura de CI.

## Decisión y alcance

`install_managed_file()` verificaba el hash del destino y luego hacía un
renombrado destructivo. El diario H1 conservaba una copia tomada con
anterioridad. En la prueba con HOME temporal, la base devolvió estado 0,
publicó el candidato de Bosh y perdió la edición introducida después de
la última comprobación.

Una comprobación adicional de hash reduce la ventana. Una copia o un
enlace duro al archivo observado conserva ese inodo, pero deja expuesto
un reemplazo de ruta que ocurra después. Se eligió un intercambio atómico
con una ruta privada junto al destino. Esa ruta conserva la entrada que
realmente se desplazó, incluso si otro proceso reemplazó el inodo durante
la ventana. El intercambio por sí solo tampoco permite decidir si una
publicación se debe registrar o si hubo un conflicto. El diario registra
las identidades esperadas de ambas entradas y la de su directorio privado.

El alcance es la publicación de Starship, Fastfetch, la configuración Zsh
propia de Bosh y los dos archivos de Konsole mediante
`install_managed_file()`. Las ramas que adoptan un archivo idéntico o
migran un manifiesto previo mantienen su flujo sin reemplazar el destino.

## Publicación y diario H1

1. Bajo el `flock` compartido por instalador y desinstalador, recuperar
   primero cualquier transacción pendiente del componente.
2. Registrar dispositivo, inodo, propietario, grupo, modo y SHA-256 del
   destino observado. Verificar que un respaldo recién creado coincide
   con el contenido y el modo observados. H1 mantiene la copia anterior de
   preparación, el manifiesto anterior y el candidato a manifiesto.
3. Preparar el candidato en un directorio de modo 0700
   `.bosh-managed-<clave>.<sufijo>` junto al destino. Publicar el diario
   H1 v2 en `$BOSH_STATE/.<clave>.managed-pending` antes de cambiar la
   ruta activa. La ubicación del candidato se deriva del destino, clave y
   sufijo validado. El diario no puede elegir una ruta arbitraria.
4. Para un reemplazo, comprobar antes del respaldo la versión de GNU
   coreutils y el intercambio de dos inodos sintéticos junto al destino.
   Publicar con `mv --exchange --no-copy -T`. Para una creación, usar `ln -T` para publicar de forma exclusiva y registrar el
   inodo creado. El enlace privado se retira al finalizar una creación
   validada. El inodo desplazado en un reemplazo se conserva en
   `.bosh-managed-<clave>.<sufijo>/file`.
5. Contrastar los inodos y hashes antes y después de escribir el manifiesto.
   El formato de manifiesto permanece en v1. El lector conserva la
   recuperación por hash de los diarios H1 v1 que dejó un instalador anterior.

| Destino y ruta privada | Manifiesto | Recuperación |
| --- | --- | --- |
| Destino anterior o ausente, candidato privado intacto | Anterior o ausencia prevista | Cancelar la preparación. Retirar el candidato verificado. |
| Candidato publicado, predecesor esperado conservado o alias de creación verificado | Anterior o ausencia prevista | Finalizar hacia delante a partir de `next`. |
| Mismo estado posterior a la publicación | Nuevo y verificado | Finalizar el diario de forma idempotente. |
| Inodo, contenido, tipo, permisos o manifiesto inesperados | Cualquiera | Informar del conflicto y preservar el destino, la ruta privada y el diario. |

Un fallo ordinario al escribir el manifiesto deja la publicación y el
diario pendientes. En el siguiente intento H1 verifica la publicación y
reintenta el manifiesto. La versión anterior intentaba restaurar una copia
mediante otro reemplazo. La recuperación hacia delante evita ese segundo
reemplazo y conserva el inodo anterior. Si el conflicto se manifiesta
durante la escritura, el manifiesto nuevo puede existir. Cuando el
manifiesto publicado se verifica, H1 registra el conflicto en el diario
pendiente o completado y bloquea ambos puntos de entrada para esa clave.
El bloqueo se conserva aunque los bytes vuelvan a coincidir.

## Portabilidad y límites

- En GNU coreutils, `--exchange` se incorporó en 9.5 y `--no-copy`
  en 9.2. Se necesitan ambas opciones y soporte de intercambio atómico
  para las dos rutas en el mismo sistema de archivos. En Linux se usa
  `renameat2(RENAME_EXCHANGE)`. Una opción o una operación incompatible
  produce error y preserva el diario. Las creaciones requieren enlaces
  duros y tampoco recurren a un renombrado destructivo.
  [GNU 9.5 NEWS](https://github.com/coreutils/coreutils/blob/v9.5/NEWS) ·
  [GNU 9.2 NEWS](https://github.com/coreutils/coreutils/blob/v9.2/NEWS) ·
  [Manual de GNU mv](https://www.gnu.org/software/coreutils/manual/html_node/mv-invocation.html) ·
  [renameat2(2)](https://www.man7.org/linux/man-pages/man2/rename.2.html)
- Un conflicto puede detectarse después de que el candidato quede en la
  ruta activa. Se devuelve error y se informa dónde quedó la edición.
  Un intercambio inverso automático podría desplazar un archivo que el
  editor ya volvió a cambiar.
- Un descriptor abierto antes del intercambio puede seguir escribiendo
  en el inodo retenido después de que el instalador devuelva éxito.
  Esa escritura queda accesible en la ruta privada. Su detección
  automática termina al finalizar el diario. Cada actualización que
  reemplaza un archivo conserva un inodo adicional. Su revisión y
  retirada quedan a cargo del usuario, una vez cerrados los escritores.
- El bloqueo coordina a Bosh. Las comparaciones son observaciones
  separadas y no definen una operación de comparar e intercambiar.
  Quedan fuera del modelo los cambios intencionales en el área privada
  o el manifiesto, las sustituciones concurrentes de directorios
  ancestros, la eliminación externa de la ruta activa y los cambios que
  se revierten entre comprobaciones. La reutilización de un número de
  inodo con los mismos metadatos y bytes también puede pasar
  inadvertida. El análisis compara bytes, modo,
  propietario, grupo e identidad. ACL, xattrs y marcas de tiempo no
  inferidas a partir de esos campos se conservan en el inodo desplazado,
  aunque una diferencia aislada puede pasar inadvertida.
- Se verificó recuperación tras interrupción de procesos. La
  implementación carece de barreras `fsync` y los identificadores de
  dispositivo pueden cambiar tras un remontaje o reinicio, por ejemplo
  en Btrfs. Un diario que ya no coincide se conserva para inspección.
  [Linux Btrfs](https://github.com/torvalds/linux/blob/master/fs/btrfs/inode.c)
- Antes de copiar el candidato, la preparación registra las
  identidades del directorio y del archivo esperado. Un candidato
  verificable con contenido vacío o completo se puede retirar tras una
  interrupción. Si falta el comprobante o el contenido es parcial, se
  conservan el candidato y el diario para inspección. Los diarios H1 v1
  no contienen identidad de inodo ni el archivo efectivamente desplazado.
- El desinstalador consulta H1 antes de procesar un manifiesto. Su propio
  reemplazo desde un respaldo y su eliminación por hash tienen
  comprobaciones de ruta separadas de la publicación o eliminación.
  Esos caminos tienen una ventana concurrente propia.

## Recuperación manual

1. Cerrar los editores o procesos que puedan seguir escribiendo y detener
   las operaciones de Bosh. Leer las rutas del diagnóstico con la misma
   cuenta que ejecutó el instalador. El estado predeterminado es
   `${XDG_STATE_HOME:-$HOME/.local/state}/bosh-terminal`; si se definió
   `BOSH_STATE`, usar ese valor.
2. Conservar una copia privada del destino, de todo el directorio
   `.bosh-managed-<clave>.<sufijo>`, del diario indicado y del manifiesto
   actual si existe. Preservar los respaldos originales. Inspeccionar
   cada tipo de entrada con `stat` y comparar los SHA-256 únicamente
   para archivos regulares que no sean enlaces simbólicos. En un diario
   v2, `next` contiene el manifiesto propuesto y `previous` el anterior,
   si existía. `previous_destination` es la copia de referencia previa,
   mientras que `file` en la ruta privada puede contener ediciones más
   recientes de un descriptor abierto.
3. Para un fallo de escritura con ambos inodos y su contenido esperados,
   corregir el problema de permisos o espacio y reintentar con la misma
   versión del instalador o desinstalador. La recuperación finaliza
   antes de que se procese el componente.
4. Si hay un conflicto real, comparar y conciliar ambos contenidos en
   una copia de trabajo. Conservar los ejemplares originales hasta
   decidir el contenido final. El manifiesto anterior debe acompañar a
   la generación anterior y el nuevo a la publicación que describe,
   incluidos su SHA y el respaldo asociado. Si se va a retirar
   manualmente un diario, verificar primero esa asociación, conservar
   una copia íntegra y moverlo a una ubicación privada fuera de los
   patrones `.managed-pending`, `.managed-prepare.*` y
   `.managed-completed.*`. Si se quiere conservar una versión personal,
   tener en cuenta que un destino sin manifiesto puede volver a someterse
   al flujo de primera instalación. Mantener el diario si hay dudas
   sobre qué versión o respaldo corresponde.
5. Tras un éxito, la ruta de retención se imprime en el registro. Si se
   detecta una edición tardía, recuperarla desde esa ruta y conciliarla.
   Revisar las rutas de retención antes de retirarlas y conservar las
   que puedan seguir recibiendo escrituras.

## Auditorías separadas

### Imágenes anime

`install_anime_images()` conserva una copia privada de rollback con
hash y modo original. Verifica otra vez el destino y a continuación lo
reemplaza con `mv -fT`. El diario de `bosh_anime_txn_recover()` compara
los hashes anteriores y nuevos para resolver interrupciones. Si el
editor cambia el archivo entre verificación y reemplazo, la copia de
rollback puede representar una versión anterior y el reemplazo pierde
la edición. La restauración vía `bosh_restore_rollback_file()` contiene
otra ventana entre verificación y publicación. El desinstalador elimina
imágenes mediante una comprobación de hash seguida de una eliminación.
El desarrollo posterior necesita retención real del inodo y un diario
por imagen que conserve su política de propiedad, hash y modo.

### Integración de ~/.zshrc

`integrate_zsh()` verifica el archivo completo, registra su respaldo y el
manifiesto, y luego publica con `mv -fT` para los modos que reemplazan
un archivo existente. Una edición tardía puede quedar fuera tanto del
candidato como del respaldo. `bosh_zsh_txn_recover()` coteja hashes de
archivo completo para ordenar los estados de interrupción. El hash del
bloque protege su titularidad para la desinstalación. El desinstalador
también reemplaza `.zshrc` al retirar el bloque o al restaurar un archivo
heredado, y elimina un archivo creado por Bosh cuando queda vacío. La
retención de ambas versiones debe diseñarse para esos modos y mantener el
contenido ajeno al bloque. Esta auditoría identifica los puntos del
código donde las comprobaciones y las mutaciones siguen separadas.

## Validación reproducible

Desde el repositorio, con Bash, GNU coreutils con intercambio atómico,
ShellCheck y los prerrequisitos de pruebas del proyecto:

```bash
bash tests/test-toctou-managed.sh
bash tests/test-recovery-h1.sh
setsid -w bash tests/run-tests.sh
for script in install.sh uninstall.sh scripts/*.sh scripts/lib/*.sh tests/*.sh; do
    bash -n "$script" || exit 1
done
shellcheck --norc -x -P SCRIPTDIR install.sh uninstall.sh scripts/*.sh scripts/lib/*.sh tests/*.sh
```

La prueba de edición usa `tests/helpers.sh` para crear HOME y XDG
aislados. También se prueban cambios por descriptor antes del manifiesto y
después del éxito, sustitución por otro inodo con los mismos bytes,
`SIGKILL` a ambos lados del intercambio, fallo de escritura del
manifiesto, compatibilidad del diario anterior y bloqueo de reintentos en
conflicto. El workflow ejecuta H1 y TOCTOU en el contenedor Arch, donde
está disponible `mv --exchange`. El job Ubuntu 26.04 ejecuta también
H1 y TOCTOU con herramientas GNU, junto con sintaxis, ShellCheck y
artefactos temporales.
