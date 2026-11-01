# Cambios

## 0.4.0 — 2026-11-01

Versión mejorada basada en la implementación probada 0.4.0-preview.7. El cambio de etiqueta no añade funciones respecto de esa prueba.

- Ventana propia para mpv, basada en la interfaz de SubDL. uosc opcional; ya no exige sustituir su menú.
- Consulta del catálogo de títulos mediante la API de The Subtitle Database con clave personal. Cinemeta queda como alternativa sin clave.
- Fichas en una única zona de resultados; selección explícita de película/serie, temporada y episodio, con Volver.
- Idiomas con selección múltiple; una opción Español reúne es/sp/ea. Sin selección: español e inglés. Resultados agrupados, español primero. Se eliminó Restablecer.
- Hasta cinco páginas por tanda, con continuidad mediante Revisar más.
- Revisión de aportes a nivel de temporada/serie; Otros archivos solo cuando existen candidatos sin episodio confirmado.
- Conservación de numeraciones identificadas por TSDB y de alternativas verificadas para especiales, incluido S00E01 dentro de T3 E1 de The Office británica.
- Nombre original dentro de una carpeta por ID del aporte; índice persistente y compatibilidad con dos diseños de descarga anteriores.
- Caché de consultas en RAM, actualización forzada, control de respuestas obsoletas y operaciones; reintentos acotados con Retry-After.
- Autenticación mediante entorno de curl, corrigiendo el uso de stdin_data que no transmitía la cabecera en la versión Windows de mpv probada.
- Soporte de más formatos de texto y validación antes de la carga; Activado solo cuando mpv acepta cargar el archivo.
- Guía de instalación, configuración de ejemplo, detalles de funcionamiento y pruebas reproducibles. No se incluyen claves ni descargas personales.

## 0.1.0-alpha.1 — 2026-10-29

Primera publicación: interfaz adaptada de uosc, catálogo Cinemeta y descargas desde The Subtitle Database. Conservada en el historial y en `legacy/uosc-alpha` como referencia; no forma parte de la instalación actual.
