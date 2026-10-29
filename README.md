# mpv-TSDB · v0.1.0-alpha.1

**Primera versión alfa — Buscador de subtítulos para mpv y uosc**

mpv-TSDB permite buscar subtítulos para películas y series desde el reproductor, elegir idiomas, consultar resultados, descargar archivos y cargarlos en mpv.

> **Antes de empezar:** TSDB **no es un reproductor y no funciona por separado**. Es obligatorio tener **mpv y uosc instalados y funcionando**. Esta alfa utiliza una adaptación del menú interno de uosc 5.13.0. La compatibilidad con una instalación estándar limpia de uosc aún no está verificada; por eso **es imprescindible respaldar el menú original**.

## Requisitos

- PC con Windows y acceso a Internet.
- [mpv para Windows](https://mpv.io/installation/).
- [uosc 5.13.0](https://github.com/tomasklaen/uosc/releases/tag/5.13.0), instalado dentro de mpv.
- PowerShell y `curl.exe` disponibles en Windows.
- Dos archivos necesarios para el buscador: **`tsdb.lua`** y **`Menu_TSDB_alpha.lua`**. La excepción para nombres completos es opcional y se aplica por separado.

## Instalación de TSDB: ejemplo práctico en Windows

**Para usar TSDB debes tener previamente instalado el reproductor mpv con la interfaz uosc. Ambos deben estar funcionando antes de continuar.** Si todavía no los tienes, instálalos siguiendo las instrucciones oficiales de [mpv](https://mpv.io/installation/) y [uosc](https://github.com/tomasklaen/uosc/releases/tag/5.13.0). **Esta guía no instala mpv ni uosc**; explica cómo añadir TSDB cuando los dos ya están preparados.

### Instalación que utilizaremos como ejemplo

A partir de aquí, **suponemos que mpv con uosc ya está instalado en `C:\mpv`**. No necesitas volver a instalar ninguno de los dos. Todas las rutas de la guía utilizan esa carpeta para que puedas seguir los pasos sin confundirte.

Si los instalaste en otro lugar, utiliza esa ubicación real en vez de `C:\mpv`. El resto de nombres y subcarpetas debe mantenerse igual.

### Paso 1. Comprobar los requisitos

1. Abre el **Explorador de archivos** de Windows y entra en `C:\mpv`.
2. Confirma que encuentras el programa `mpv.exe`.
3. Abre un vídeo con mpv. Al mover el cursor sobre el reproductor debes ver los controles de **uosc** y poder utilizarlos.
4. Cierra mpv.
5. Abre la carpeta `C:\mpv\portable_config\scripts\uosc\elements\`.
6. Confirma que existe el archivo `Menu.lua`. Este archivo pertenece a uosc y será necesario para instalar la interfaz adaptada de TSDB.

**Si uosc no funciona o no existe `Menu.lua` en esa ubicación, detente.** Revisa dónde instalaste uosc y comprueba que su estructura es compatible antes de sustituir archivos.

En este ejemplo, antes de descargar TSDB ya tienes:

~~~text
C:\mpv\
├── mpv.exe
└── portable_config\
    └── scripts\
        ├── uosc.lua
        └── uosc\
            └── elements\
                └── Menu.lua    ← ARCHIVO ORIGINAL DE UOSC
~~~

La instalación de uosc contiene más archivos de los que aparecen aquí. **No los borres ni los cambies**.

### Paso 2. Descargar los archivos de TSDB

**Descargar los dos Lua necesarios**

Abre esta carpeta de GitHub (la rama de la primera alfa) y descarga los dos Lua: **`tsdb.lua`** y **`Menu_TSDB_alpha.lua`**.

En GitHub, abre cada uno, haz clic en **Raw** y guarda el contenido en **Descargas** con su nombre y extensión `.lua`.

| Archivo disponible en la carpeta alfa | Qué hacer |
| --- | --- |
| **`tsdb.lua`** | Descargar: es el buscador |
| **`Menu_TSDB_alpha.lua`** | Descargar: es el menú adaptado |
| `ACTIVAR_NOMBRES_TSDB.ps1` | Opcional: conserva los nombres de pistas `[TSDB]` sin reemplazar `menus.lua` completo |
| `README.md` | Solo documentación; no va dentro de `scripts` |
| `LICENSE.LGPL` | Licencia; consérvala junto a los archivos distribuidos, no dentro de `scripts` |

En Windows activa **Explorador > Vista > Extensiones de nombre de archivo**. Comprueba que no se hayan guardado como `tsdb.lua.txt` o `Menu_TSDB_alpha.lua.txt`.

### Paso 3. Respaldar los archivos antes de instalar TSDB

1. **Cierra por completo mpv**.
2. Dentro de `C:\mpv`, crea la carpeta **`respaldos`**. No la crees dentro de `scripts`.
3. Abre `C:\mpv\portable_config\scripts\uosc\elements\`.
4. **Copia** el archivo `Menu.lua` y **pégalo** en `C:\mpv\respaldos\`. No cortes el original.
5. Verifica que el respaldo existe: `C:\mpv\respaldos\Menu.lua`.
6. Si ya existía una instalación anterior de TSDB con `tsdb.lua`, guarda también una copia de ese Lua en `C:\mpv\respaldos\tsdb.lua`. Si es tu primera instalación de TSDB, este archivo todavía no existe y no necesitas ese segundo respaldo.

**Tabla completa de respaldos:**

| Archivo original | Copia que debes guardar | ¿Es obligatorio? |
| --- | --- | --- |
| `C:\mpv\portable_config\scripts\uosc\elements\Menu.lua` | `C:\mpv\respaldos\Menu.lua` | **Sí, siempre** |
| `C:\mpv\portable_config\scripts\tsdb.lua`, si ya existe | `C:\mpv\respaldos\tsdb.lua` | Solo si existía |
| `uosc.lua`, `uosc.conf`, fuentes, otros elementos de uosc | **No se modifican durante la instalación de TSDB** | No hay que moverlos ni reemplazarlos |

> Si no has conseguido copiar correctamente `Menu.lua` a `respaldos`, **no sigas**: es el archivo que necesitarás para recuperar el menú original de uosc.

## Copiar los archivos a sus carpetas

### Paso 4. Copiar el buscador

1. Ve a **Descargas**.
2. Copia **`tsdb.lua`**.
3. Abre `C:\mpv\portable_config\scripts\`.
4. Pega el archivo. Su nombre final sigue siendo **`tsdb.lua`**: no hay que renombrarlo.

### Paso 5. Sustituir el menú

1. Ve a **Descargas** y copia **`Menu_TSDB_alpha.lua`**.
2. Pégalo en `C:\mpv\portable_config\scripts\uosc\elements\`.
3. Allí, **renombra la copia** `Menu_TSDB_alpha.lua` a **`Menu.lua`**.
4. Windows avisará de que ya existe un archivo llamado `Menu.lua`: elige **Reemplazar el archivo en el destino**.
5. Hazlo **solo después de comprobar el respaldo** realizado en el paso 3.

**Qué ocurre al reemplazar:** el `Menu.lua` modificado de TSDB **sustituye** al `Menu.lua` original en la carpeta activa de uosc. **No se combinan los códigos ni se mantienen ambos menús activos.** El archivo original **no se pierde**, porque antes lo copiaste a `C:\mpv\respaldos\Menu.lua`. Si deseas volver a uosc sin esta modificación, restaura esa copia.

**Resumen definitivo de todos los archivos que se copian para TSDB:**

| Desde (origen) | Hasta (destino) | Operación |
| --- | --- | --- |
| `Descargas\tsdb.lua` | `C:\mpv\portable_config\scripts\tsdb.lua` | **Copiar**, mantener nombre |
| `Descargas\Menu_TSDB_alpha.lua` | `C:\mpv\portable_config\scripts\uosc\elements\Menu.lua` | **Copiar, renombrar a `Menu.lua` y reemplazar** |
| `C:\mpv\portable_config\scripts\uosc\elements\Menu.lua` **original** | `C:\mpv\respaldos\Menu.lua` | **Respaldar ANTES** de reemplazarlo |
| `README.md` y `LICENSE.LGPL` | No tienen ubicación obligatoria dentro de mpv | Conservar con la distribución; **no** copiar a `scripts` |

### Paso 6. Comprobar cómo quedaron las carpetas

~~~text
C:\mpv\
├── mpv.exe
├── [otros archivos de mpv]
├── respaldos\
│   └── Menu.lua                      ← ORIGINAL DE UOSC (RESPALDO)
└── portable_config\
    ├── fonts\
    │   ├── uosc_icons.otf
    │   └── uosc_textures.ttf
    ├── script-opts\
    │   └── uosc.conf
    └── scripts\
        ├── uosc.lua
        ├── tsdb.lua                   ← BUSCADOR NUEVO
        ├── uosc_shared\              ← si está incluida en uosc
        └── uosc\
            ├── [demás componentes de uosc]
            └── elements\
                ├── Element.lua
                ├── Menu.lua           ← MENÚ ADAPTADO DE TSDB
                └── [otros elementos de uosc]
~~~

**Para la función principal instalamos solo dos Lua**: `tsdb.lua` y la adaptación `Menu.lua`. Opcionalmente, el parche de nombres completos ajusta **dos líneas** de `uosc/lib/menus.lua` y guarda su original.

## Primera ejecución de TSDB

### Paso 7. Abrir la interfaz

1. Abre mpv y reproduce algún vídeo.
2. Presiona **Ctrl + Shift + T**.
3. Debería aparecer un menú con el cuadro **Buscar película, serie o IMDb…**. No necesitas editar `input.conf`: el atajo ya está incorporado.

### Paso 8. Probar una búsqueda

1. Escribe `Matrix 1999`.
2. Pulsa **Enter**.
3. TSDB intentará consultar Cinemeta y The Subtitle Database; los resultados dependen de la disponibilidad de los servicios.
4. Pulsa **Idioma de búsqueda** si quieres elegir un idioma para una consulta.
5. Pulsa **Filtrar resultados** para mostrar solo los idiomas que te interesen. Puedes marcar varios idiomas seguidos y cerrar el desplegable al terminar.
6. Elige un resultado disponible. TSDB intentará descargar y cargar ese subtítulo en mpv.
7. Comprueba en la lista de pistas de subtítulos del reproductor que aparece el subtítulo cargado.

**Instalación completada:** si se abre el menú, puedes buscar y el vídeo muestra la pista descargada, has terminado. El subtítulo escogido puede no coincidir o estar sincronizado con todas las versiones de una película.

## Opcional: conservar los nombres completos de las pistas [TSDB]

**No es necesario para abrir el buscador, buscar ni descargar subtítulos.** uosc 5.13.0 puede acortar el nombre de algunas pistas externas al compararlo con el nombre del vídeo. Para impedir esa limpieza *solo* en las pistas marcadas con `[TSDB]`, se incluye `ACTIVAR_NOMBRES_TSDB.ps1`.

Este archivo **no es otro script de mpv**: es una herramienta opcional para aplicar una modificación pequeña a `uosc/lib/menus.lua`. **No lo copies dentro de `portable_config/scripts`.** El cambio conserva los nombres aportados por TSDB; un nombre demasiado largo todavía puede no caber visualmente en una fila.

**Qué cambia al aplicarlo:** sin la excepción, uosc puede quitar del nombre de una pista externa las partes que coinciden con el archivo de vídeo y una supuesta extensión. En algunos casos no ocurre y el título se ve completo. Con la excepción, las pistas etiquetadas `[TSDB]` se excluyen de esa limpieza, mientras que el resto de pistas conserva el comportamiento normal. No altera los archivos SRT ni la búsqueda o descarga de TSDB.

### Activar la excepción en Windows

1. Cierra mpv.
2. Descarga `ACTIVAR_NOMBRES_TSDB.ps1` desde esta misma carpeta de GitHub y guárdalo en la carpeta donde está `mpv.exe`. Por ejemplo, `C:\mpv\ACTIVAR_NOMBRES_TSDB.ps1`.
3. Desde la carpeta `C:\mpv`, escribe `cmd` en la barra de direcciones del Explorador y presiona Enter.
4. Ejecuta exactamente:

```bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "ACTIVAR_NOMBRES_TSDB.ps1"
```

5. Si se confirma la modificación, reinicia mpv. El original queda respaldado automáticamente en `C:\mpv\portable_config\tsdb-backups\menus.lua.before-tsdb.bak`.

Para **restaurar únicamente esa excepción** y volver al `menus.lua` anterior, cierra mpv y ejecuta desde `C:\mpv`:

```bat
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "ACTIVAR_NOMBRES_TSDB.ps1" -Restore
```

La restauración se detiene sin sobrescribir nada si `menus.lua` fue modificado posteriormente. El parche también se detiene sin cambios si la rutina esperada de uosc 5.13.0 es diferente; nunca debe forzarse sobre versiones desconocidas. **Prueba realizada el 29 de octubre de 2026:** el parche se aplicó correctamente en una instalación de prueba separada con uosc 5.13.0 y Hikari. En el menú de pistas se mostró el nombre largo `Arsenal.1929.(Aleksandr.Dovzhenko-Trilogy).720p.x264-Classics [TSDB]`. Esto confirma la aplicación del parche y la visualización de ese caso; **no garantiza compatibilidad con todas las instalaciones ni que cualquier nombre quepa en el ancho del menú**.

## Cómo desinstalar TSDB y recuperar uosc

1. Cierra mpv.
2. Elimina de `C:\mpv\portable_config\scripts\` el archivo **`tsdb.lua`** que instalaste.
3. Abre `C:\mpv\respaldos\` y copia el **`Menu.lua` original** guardado.
4. Pégalo en `C:\mpv\portable_config\scripts\uosc\elements\` y acepta reemplazar el archivo actual.
5. Reinicia mpv y comprueba que los controles originales de uosc han regresado.
6. Si había un `tsdb.lua` anterior y guardaste su respaldo, podrás restaurarlo de la misma forma cuando corresponda.

No borres uosc completo: para desinstalar TSDB basta con eliminar el Lua del buscador y devolver el menú original. Si aplicaste la excepción opcional de nombres, restaúrala antes con `ACTIVAR_NOMBRES_TSDB.ps1 -Restore`, como se indica arriba.

## Problemas frecuentes

| Problema | Solución |
| --- | --- |
| mpv no abre | Comprueba que extrajiste **toda** su distribución, no solo `mpv.exe`. |
| No aparece uosc | Comprueba que se instaló correctamente; según el paquete, puede cargarse desde `scripts\uosc\main.lua` sin un `uosc.lua` separado. |
| No existe `elements\Menu.lua` | No instales TSDB aún; comprueba la instalación y versión de uosc. |
| Ctrl + Shift + T no abre TSDB | Revisa `portable_config\scripts\tsdb.lua`, reinicia mpv y evita duplicados del buscador. |
| El menú de uosc falla después de instalar TSDB | Restaura el `Menu.lua` guardado en `respaldos`; la versión de uosc puede ser incompatible. |
| No hay resultados | Comprueba Internet, `curl.exe`, el título o IMDb buscado y la disponibilidad de los servicios. |

## Compatibilidad y licencia

Este procedimiento es un **ejemplo didáctico de instalación manual**, no una prueba ejecutada en otro ordenador. La alfa fue desarrollada sobre una personalización de **uosc 5.13.0**. No se garantiza que la sustitución de `Menu.lua` funcione en todas las configuraciones de uosc.

`Menu_TSDB_alpha.lua` es una adaptación de uosc, de [tomasklaen](https://github.com/tomasklaen/uosc) y sus colaboradores, y contiene código sujeto a la licencia LGPL-2.1 suministrada en `LICENSE.LGPL`. El proyecto es independiente y no está afiliado a The Subtitle Database, Cinemeta, Stremio ni uosc.

Para incidencias, consulta el hilo de esta alfa en la pestaña **Issues** del repositorio.
