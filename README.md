# mpv-TSDB · 0.4.0

**mpv-TSDB es un proyecto independiente** para buscar y cargar subtítulos en mpv en Windows. Consulta la base de datos de **The Subtitle Database (TSDB)** mediante su API y permite buscar por película, serie, temporada, episodio e idiomas.

Se instala con `tsdb.lua` y un archivo de configuración, e incluye su propia ventana compacta. Las versiones anteriores se conservan en [legacy](legacy/README.md).

[Descargar el paquete 0.4.0](dist/mpv-tsdb-v0.4.0.zip?raw=true) · [Cambios](CHANGELOG.md) · [Detalles y límites](docs/FUNCIONAMIENTO.md) · [Pruebas](docs/VALIDACION.md)

## Requisitos

- Windows, [mpv instalado](https://mpv.io/installation/) y conexión a Internet.
- `curl.exe` **8.3 o posterior** disponible en PATH. Se comprobó con curl 8.13.0. Puedes consultar tu versión con `curl.exe --version`.
- Windows PowerShell para crear las carpetas de descarga.
- Una clave personal de [TSDB](https://thesubtitledb.org/developer/api) para consultar títulos mediante su API. Sin clave se conserva Cinemeta como alternativa para identificar fichas; los subtítulos siguen procediendo de TSDB.

## Instalación en mpv portable

El ejemplo usa `D:\mpv`. Si tu reproductor está en otro lugar, cambia esa parte de las rutas.

1. Cierra mpv. Descarga y extrae el [paquete](dist/mpv-tsdb-v0.4.0.zip?raw=true).
2. Si ya usabas mpv-TSDB, mueve su Lua anterior fuera de `portable_config\scripts`, por ejemplo a `D:\mpv\portable_config\tsdb-respaldos`. No dejes dos versiones activas, ni respaldos `.lua` en subcarpetas de `scripts`.
3. Copia **`tsdb.lua`** a `D:\mpv\portable_config\scripts\tsdb.lua`.
4. Si no tienes configuración de esta versión, copia `tsdb.conf.example` a `D:\mpv\portable_config\script-opts\tsdb.conf`. Crea `script-opts` si falta. Activa las extensiones de archivo de Windows para evitar guardarlo como `.conf.txt`.
5. Edita `tsdb.conf`: escribe únicamente tu clave después de `api_key=`, sin comillas ni `Bearer`. **Si ya tenías un `tsdb.conf` válido de la versión de prueba, consérvalo.** La antigua configuración `tsdb_desarrollo.conf` corresponde a otro script y no se lee automáticamente.

Estructura mínima:

```text
D:\mpv\
├── mpv.exe
└── portable_config\
    ├── scripts\
    │   └── tsdb.lua
    ├── script-opts\
    │   └── tsdb.conf       ← tu clave privada; no se distribuye
    └── tsdb-subtitles\    ← se crea al descargar
```

Los archivos `PROBAR_TSDB.cmd` y `CONFIGURAR_API.cmd` son herramientas de prueba/configuración: **no van dentro de `scripts`**.

## Si vienes de la carpeta de prueba

Copia su `config\script-opts\tsdb.conf` a `portable_config\script-opts\tsdb.conf`. Para conservar descargas, copia también el contenido de `config\tsdb-subtitles` a `portable_config\tsdb-subtitles`, manteniendo carpetas, nombres y `download-index.json`. Conserva un respaldo si el destino ya contiene otro índice; no borres los subtítulos existentes.

Las copias de diseños anteriores se siguen reconociendo. La reutilización solo puede ocurrir cuando los archivos estén en la carpeta de subtítulos de la configuración que usa ese mpv.

Si instalaste la alfa antigua con un `Menu.lua` adaptado, la nueva versión ya no depende de él. Esta actualización no lo modifica ni lo restaura automáticamente; cualquier restauración debe respetar los cambios que hayas hecho para otros scripts.

## Uso

1. Al abrir la ventana se rellena el buscador con el nombre del vídeo. Puedes corregirlo; después se conserva lo que escribas. Abrir la ventana no inicia una búsqueda.
2. Elige **Película** o **Serie**. En series ajusta **Temporada** y **Episodio**; temporada 0 está permitida.
3. El botón **Idiomas**, debajo de Buscar, permite marcar uno o varios. **Español** agrupa todas sus variantes. Sin ninguna selección se solicitan español e inglés. Marcar o desmarcar no consulta la API.
4. Pulsa **Buscar**. Todas las fichas aparecen en **Resultados**; elige la correcta por nombre y año. Al abrirla se buscan sus subtítulos con los filtros elegidos.
5. Elige un subtítulo para descargarlo y activarlo en el vídeo abierto. Una búsqueda manual puede ser de otro título: comprueba tu elección.

Los resultados recibidos se agrupan: español primero, inglés después y luego los demás idiomas. Los cambios de idioma o T/E se aplican al volver a pulsar Buscar. **Volver** regresa a la lista anterior.

- **Revisar más:** continúa las páginas o niveles que faltan; se revisan hasta **cinco páginas por tanda**, con hasta 100 elementos por página de forma predeterminada. No descarga archivos. Una página de la API no es una línea de la lista ni una ficha.
- **Otros archivos:** aparece como una fila dentro de resultados solo cuando se recuperan aportes adicionales de esa serie sin episodio confirmado. Permite revisión manual y conserva Volver.
- Pasa el ratón por un subtítulo para leer el nombre completo. La lista y el desplegable de idiomas admiten desplazamiento; la barra de resultados se puede arrastrar.
  
La sincronización depende del aporte y de la edición del vídeo.

## Nombres, descargas y caché

Los aportes nuevos conservan el nombre publicado por TSDB dentro de una carpeta identificada:

```text
tsdb-subtitles\Lupin (2021) [TSDB-ID-del-aporte]\Nombre original.srt
```

Se adaptan los caracteres que Windows no permite y los nombres que superan el límite de un componente. Aportes distintos con igual nombre conservan IDs y carpetas distintos. `download-index.json` permite reutilizar una copia válida incluso si cambia el nombre mostrado. También se reconocen `TSDB-ID.ext` y el diseño anterior `Título [TSDB-IMDb]\Nombre [ID].ext`.

La caché de consultas es **en RAM, durante esa sesión de mpv**: 30 minutos para resultados y 5 para listas vacías; máximo 50 respuestas y 10 MiB de texto. Las claves incluyen ruta de la ficha/T/E, idiomas y página. Las listas generales reutilizadas se vuelven a clasificar para el episodio solicitado. Cerrar mpv libera esa caché, pero los subtítulos descargados permanecen en disco.

## Formatos y límites

Se admiten estructuras de texto reconocidas de SRT, ASS, SSA, VTT, MicroDVD/SUB, SubViewer, MPL2, TMPlayer, MPsub y SAMI. **La extensión `.sub` no identifica por sí sola el formato**: VobSub binario con su IDX y USF no están habilitados en este adaptador.

Se rechazan HTML y archivos inválidos; se comprueba que la URL de descarga corresponda al servicio, se acotan los reintentos y se respeta Retry-After. Cambiar de vídeo impide aplicar respuestas pendientes del anterior. Las consultas más amplias pueden encontrar aportes que no corresponden al episodio: [cómo se clasifican](docs/FUNCIONAMIENTO.md).

## Problemas frecuentes

| Problema | Comprobación |
| --- | --- |
| Ctrl+Shift+T no abre la ventana | Verifica `scripts\tsdb.lua`, reinicia mpv y retira versiones duplicadas. Comprueba posibles conflictos del atajo. |
| Error de clave | Revisa `script-opts\tsdb.conf`, guarda y reinicia mpv. Usa solo la clave, sin `Bearer`. |
| curl no reconoce `--variable` o `--expand-header` | Hace falta curl 8.3 o posterior en PATH. |
| No hay resultados | Revisa el título/IMDb, Película/Serie, T/E, idiomas y disponibilidad del servicio. No se inventan coincidencias. |
| Cambié opciones pero veo la lista anterior | Pulsa Buscar para aplicar los cambios. |
| Aparece Revisar más | Quedan páginas o niveles de la ficha por revisar. |
| Parece que se repite un nombre | Pueden ser aportes diferentes; se distingue por ID, no solo por nombre. |
| No se puede activar | Abre un vídeo. Comprueba el formato y el mensaje mostrado; Activado exige que mpv acepte el archivo. |

## Desarrollo y procedencia

El Lua distribuido se construye desde [src](src) mediante `python tools/build.py`. Las pruebas se ejecutan con [tests/run_tests.ps1](tests/run_tests.ps1), sin clave real y con respuestas controladas. Consulta [VALIDACION.md](docs/VALIDACION.md) para distinguir pruebas locales y comprobaciones reales del usuario.

La ventana deriva del trabajo de SubDL bajo MIT; la lógica de búsqueda y descarga consulta la API de The Subtitle Database. La versión actual se distribuye bajo [MIT](LICENSE.MIT). Los archivos históricos del menú de uosc conservan sus avisos y [LGPL-2.1](legacy/uosc-alpha/LICENSE.LGPL). No hay afiliación con TSDB, Cinemeta, Stremio ni uosc.
