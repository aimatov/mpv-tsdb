# Validación de 0.4.0

Publicación de la implementación 0.4.0-preview.7 probada con el usuario. Solo cambia la identificación de versión, los avisos de licencia y la presentación de la distribución; las funciones del Lua se mantienen.

## Pruebas reproducibles

Con mpv en Windows, desde la raíz del repositorio:

```powershell
.\tests\run_tests.ps1 -MpvPath D:\mpv\mpv.exe
```

El ejecutor crea una carpeta temporal diferente por prueba y no carga la configuración ni otros scripts del mpv instalado. No usa una clave real ni consulta la API de TSDB. Comprueba el marcador PASS y los errores de Lua, además del código de salida: este último por sí solo no basta para detectar un fallo de inicialización de un script.

| Prueba | Cobertura |
| --- | --- |
| test_tsdb | Ventana sin consulta al abrir, categoría, ficha explícita, T/E, paginación, caché/TTL/LRU, actualización forzada, errores no guardados, descarga/reutilización, HTML y host no oficial, respuestas obsoletas. |
| test_native_api | Catálogo TSDB con clave simulada, categorías, idioma, paginación y Volver; clave fuera de URL/argumentos; Retry-After y reintentos; SUB y carga fallida. |
| test_features6 | Selector múltiple y valores predeterminados al desmarcar; ausencia de Restablecer; Volver libre; agrupación; aislamiento por idioma; clasificación con respuestas reales guardadas; Otros archivos condicional; especiales; nombre original, IDs distintos, índice persistente y diseños anteriores. El nombre del archivo conserva el número de la revisión donde se añadió. |
| test_five_pages | Cinco páginas consecutivas por tanda; continuación en la sexta; finalización y reutilización de las siete páginas guardadas sin nuevas solicitudes. |
| test_buttons_real | Despacho real de script-message-to de mpv para temporada y episodio +/−. |
| test_formats_real | Validación, carga y texto decodificado en mpv de ocho archivos sintéticos: MicroDVD, MPL2, SubViewer, TMPlayer, SAMI con dos extensiones, MPsub y SRT. |

Los ejemplos SAMI pueden producir un aviso del decodificador durante la prueba, aunque se comprueba el texto esperado en su tiempo. No se declara compatibilidad con cualquier archivo que tenga esa extensión.

## Datos de cotejo

`tests/fixtures` conserva una proyección mínima de respuestas de la API TSDB obtenidas el 31 de octubre de 2026 para The Office británica y Lupin. Solo se guardan campos de identidad, clasificación y presentación necesarios para las pruebas; se omiten claves, datos de usuarios y enlaces de descarga. Los subtítulos de texto de `fixtures/formats` y el vídeo Y4M son sintéticos.

El cotejo confirmó:

- The Office británica tiene aportes generales de serie/temporada que no aparecen en la consulta de T1 E1: justifican la revisión de Otros archivos.
- Lupin no tenía aportes en esos grupos generales en las respuestas cotejadas: no se debe inventar una sección vacía.
- Nombres [1.01], 1.3 y 2.4 tienen contexto de episodio en TSDB.
- Dos archivos denominados S00E01 se entregan en T3 E1 de The Office y constan en el árbol de ese mismo episodio especial.

Estas son capturas de datos, no una garantía de que el catálogo actual mantenga los mismos recuentos o clasificación.

## Comprobaciones reales realizadas durante el desarrollo

- Una petición autenticada al buscador TSDB devolvió HTTP 200 y fichas de Lupin.
- Se reprodujo y corrigió la ausencia de cabecera al usar stdin_data de mpv en Windows. Una prueba local con mpv, curl y un servidor de comprobación confirmó la transmisión mediante el entorno del proceso.
- El usuario confirmó búsquedas de Lupin por episodio y la descarga, activación y sincronización de un aporte de Akira. También revisó la ventana y sus cambios posteriores.

Esto valida los casos probados, no todos los catálogos, conexiones ni ordenadores. No se hizo un benchmark de velocidad de descarga ni una medición aislada y concluyente de recursos de esta publicación. La sincronización depende del aporte y de la edición del vídeo.

## Construcción y paquete

```powershell
python tools/build.py
```

Se conserva `src` para reconstruir el Lua distribuido. La distribución se prepara con una lista explícita de archivos y sin la carpeta `config`, índices, registros ni subtítulos personales. Las credenciales de prueba son valores ficticios sin utilidad en el servicio.
