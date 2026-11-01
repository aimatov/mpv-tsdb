# TSDB para mpv — 0.4.0

## Actualizar conservando clave y descargas

Cierra el mpv de prueba anterior. Sustituye unicamente `tsdb.lua` en su carpeta por el de esta entrega y vuelve a ejecutar PROBAR_TSDB.cmd. Conserva su carpeta `config`: contiene tu configuracion privada y los subtitulos guardados.

Si empiezas desde una carpeta nueva: extrae el ZIP, ejecuta CONFIGURAR_API.cmd, escribe tu clave despues de `api_key=` y guarda. Ejecuta PROBAR_TSDB.cmd y abre un video. Ctrl+Shift+T abre TSDB. El lanzador busca D:\mpv\mpv.exe o mpv.exe junto al Lua; puedes editar su ruta. Requiere curl 8.3 o posterior. No instala ni reemplaza scripts en D:\mpv.

## Idiomas

El boton Idiomas esta debajo de Buscar y abre un menu con casillas. Puedes seleccionar uno o varios idiomas; marcar casillas no hace consultas. Usa la rueda o arrastra la barra del menu para ver mas idiomas. Esc o un clic fuera del desplegable lo cierra. Volver conserva su posicion y queda libre a la derecha.

Español es una sola opcion e incluye es, sp y ea. Sin ninguna casilla marcada se solicitan Español e Ingles. Basta con desmarcar las casillas; no hay boton Restablecer. Si marcas idiomas se solicitan solo esos. Chino incluye zh y zt; Portugues incluye pt y pb. Una configuracion languages explicita distinta del valor predeterminado se refleja en las casillas al iniciar.

Pulsa Buscar para aplicar los idiomas, pelicula/serie y T/E. Los resultados recibidos se agrupan con Español primero, Ingles despues y los demas idiomas por grupo. Las paginas que aun no se hayan revisado pueden aportar mas resultados: pulsa Revisar mas cuando se indique.

## Numeracion y Otros archivos

Para una serie se consulta el episodio solicitado y tambien se revisan las listas generales de esa temporada y de la serie. Se usa la identidad de la ficha IMDb seleccionada, nunca una busqueda libre de otras series. Las consultas respetan los idiomas y la cache; revisar estos niveles puede requerir mas solicitudes que buscar solo el episodio.

- Se reconocen S01E01 y variantes con separadores, 1x01, [1.01] y la forma delimitada ` - 1.3 - ` verificada en TSDB. No se convierten decimales sueltos, H.264 o versiones en episodios.
- Los archivos ya asignados por TSDB al episodio aparecen en resultados normales cuando no hay una contradiccion confirmada.
- Para especiales se acepta la numeracion S00 cuando el arbol de TSDB identifica ese mismo archivo, por su ID, dentro del episodio especial solicitado. Se comprobo The Office britanica: nombres S00E01 dentro de T3 E1. El nombre completo al pasar el mouse indica la numeracion alternativa confirmada.
- Otros archivos es una fila al final de resultados. Solo aparece si hay aportes adicionales de la misma ficha cuya numeracion no se puede confirmar. Al entrar, Volver regresa a los subtitulos normales. Su seleccion es manual: pertenecer a la serie no garantiza que corresponda al episodio solicitado.
- Los archivos identificados como otro episodio se excluyen. No se vacia la proteccion T/E para toda la serie por contener especiales.

Las respuestas amplias pueden contener un arbol de varios idiomas: solo se lee su identidad T/E. Los archivos ofrecidos se obtienen de las listas filtradas y se vuelven a comprobar localmente contra los idiomas seleccionados.

La revision se limita a cinco paginas por lote y 100 elementos por pagina de forma predeterminada. Revisar mas continua lo que falte, incluidos los niveles de temporada o serie; Volver no hace una consulta nueva.

## Nombres y reutilizacion

Cada aporte nuevo se guarda en `config/tsdb-subtitles/Titulo (año) [TSDB-ID]/Nombre original.ext`. El ID pertenece al aporte y no se añade al nombre del archivo. Se usa el release_name publicado por TSDB y su extension declarada. Se sustituyen caracteres que Windows no permite y se limita el nombre cuando excede el tamaño admitido de un componente.

Dos aportes con igual nombre e IDs distintos conservan carpetas distintas. `download-index.json` asocia cada ID a su archivo guardado, para reutilizarlo incluso si cambia el titulo mostrado. No contiene claves. Copia toda la carpeta de subtitulos si quieres trasladar esas asociaciones.

Se siguen reconociendo los dos diseños anteriores: TSDB-ID.ext y Titulo [TSDB-IMDb]/Nombre [ID].ext. No se renombran ni se borran las descargas anteriores. Un archivo ausente o invalido se puede descargar de nuevo. La copia debe estar en la carpeta de subtitulos de la configuracion que estes usando.

## Protecciones conservadas

Cache en RAM por URL completa: ficha, ruta T/E, idiomas y pagina. Resultados durante 30 minutos; listas vacias durante 5 minutos; limite de 50 respuestas y 10 MiB. Ctrl+clic en Buscar fuerza la actualizacion. Las listas generales de una misma serie pueden reutilizarse entre episodios porque su contenido es el mismo; cada resultado se vuelve a clasificar para el T/E solicitado.

Se conservan la reutilizacion de archivos validos, el control de operaciones, los limites de descarga, el rechazo de HTML, las comprobaciones de URL oficial, los reintentos acotados y Retry-After. Las respuestas pendientes no se aplican si cambias de video. Una busqueda manual puede cargar el aporte que elijas en el video actual.

La clave se lee de config/script-opts/tsdb.conf y se transmite a curl mediante el entorno del proceso. No se incluye en el Lua, los argumentos, los archivos temporales de autenticacion ni el ZIP.

## Comprobaciones de esta entrega

Pasaron pruebas de seleccion multiple y valores predeterminados, boton Volver libre, agrupacion, aislamiento de cache por idiomas/T/E, paginacion, reintentos, respuestas obsoletas, nombres originales, IDs distintos y reutilizacion de los diseños anteriores. Se comprobo el indice persistente al recargarlo y cambiar los nombres mostrados.

Se usaron las respuestas reales de TSDB guardadas durante el cotejo de The Office britanica y Lupin: Otros archivos aparece en el primer caso y no se inventa una seccion vacia en el segundo. Pasaron el despacho real de +/- de mpv y las pruebas locales de formatos. No se hicieron nuevas descargas de la API para estas pruebas ni se midieron mejoras de velocidad.

Buscador nativo con clave TSDB; Cinemeta sigue como alternativa sin clave. Formatos: SRT, ASS, SSA, VTT, MicroDVD/SUB, SubViewer, MPL2, TMPlayer, MPsub y SAMI de texto reconocible. No se habilitan VobSub binario/IDX ni USF. Se mantienen los controles de reproduccion de mpv al cerrar la ventana.

Referencia oficial: https://thesubtitledb.org/developer/api

Interfaz derivada de SubDL, con licencia MIT; adaptador TSDB independiente. Esta es la entrega 0.4.0, basada en la version de prueba validada.
