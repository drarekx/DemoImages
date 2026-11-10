# DemoImages

App de macOS (Dock, ventana normal) para guardar imágenes (y vídeos) de prueba en álbumes y optimizarlos a formatos modernos. Swift + AppKit/SwiftUI, sin dependencias en el código. Repo previsto: https://github.com/drarekx/DemoImages (constante `AppInfo.repo` en `AppDelegate.swift`, también en `install.sh` y README).

Estructura, instalador, actualizador, tema y traducciones heredados de Wallpy (https://github.com/drarekx/Wallpy). La optimización replica Squoosh (squoosh.app), analizado con REA: mismos codecs y valores por defecto, leídos de su chunk `Compress-*.js`.

## Compilar y ejecutar

```sh
swift build                      # debug, comprobación rápida
./build-app.sh                   # release → build/DemoImages.app + build/DemoImages.zip (universal con Xcode; nativo con solo CLT)
VERSION=1.2.0 ./build-app.sh     # versión en Info.plist (por defecto 1.0.0)
open build/DemoImages.app
open -a "$PWD/build/DemoImages.app" foto.png   # abrir archivos = importarlos al álbum actual
```

- Requisitos: macOS 14+. `Package.swift` usa tools 5.10 (modo Swift 5).
- No hay tests. Verificar compilando y lanzando la app. Para probar codificadores sin UI, compilar `Optimizer.swift` + `Video.swift` + `ExternalTools.swift` + `Localization.swift` + `Library.swift` + `Thumbnails.swift` + `Theme.swift` con un `main.swift` que defina `AppInfo` y llame a `ImageEncoder.encode` o `VideoEncoder.encode`.
- La copia de `build/` tiene versión 1.0.0, así que su actualizador siempre ve versiones nuevas.

## Publicar una versión

```sh
git tag v1.0.1 && git push origin v1.0.1
```

`.github/workflows/release.yml` (macos-15) compila con `VERSION` = tag y crea el release con `DemoImages.zip` y `DemoImages.zip.sha256`. `Updater.swift` consulta `releases/latest`, verifica el SHA-256 y el `Info.plist` y cambia el bundle. `build.yml` compila arm64 + x86_64 y verifica que `en` y `ca` tienen las mismas claves y que todo `tr()` está traducido. La app no está notarizada (firma ad-hoc).

## Estructura (`Sources/DemoImages/`)

| Archivo | Qué hace |
|---|---|
| `main.swift`, `AppDelegate.swift` | Arranque, `AppInfo`, ventana principal, menú principal, `AppCommands` (⌘A/⌘C/⌘V/⌘⌫ sin campo de texto llegan al delegado y se reenvían a la galería), abrir archivos desde Finder/Dock |
| `Library.swift` | Modelo `Album` / `ImageItem` (imagen o vídeo), `library.json`, ubicación configurable (mover / abrir otra, iCloud), importar (carpetas recursivas), mover/copiar entre álbumes y a carpetas, reemplazar, renombrar, papelera |
| `Thumbnails.swift` | `ThumbnailCache` (ImageIO, cola de 4; fotograma con AVFoundation en vídeos), vista `Thumbnail`, `Checkerboard` |
| `Optimizer.swift` | `Codec`, `OptimizeOptions` (valores de Squoosh), `ImageEncoder` (decodificar con orientación, Lanczos en Core Image, cwebp/avifenc/cjxl/MozJPEG/pngquant/oxipng o ImageIO), `OptimizeRunner` (lote en paralelo a una carpeta temporal; recibe el codificador como closure, sirve para imágenes y vídeos) |
| `Video.swift` | Vídeos con AVFoundation: `VideoFile` (tipo, tamaño, duración, fotogramas), `VideoOptions` / `VideoEncoder` (HEVC o H.264 con presets de `AVAssetExportSession`), `VideoPlayerView` (AVKit) |
| `ExternalTools.swift` | Localiza y ejecuta los codificadores de Homebrew (`ToolProcess`) |
| `MainView.swift` | Barra lateral de álbumes (soltar archivos sobre un álbum los importa), tarjeta de ubicación y tamaño total (`StorageCard`), alertas de crear/renombrar/eliminar |
| `GalleryView.swift` | Cabecera, barra de acciones, cuadrícula con selección múltiple, arrastrar dentro/fuera, menú contextual, pie |
| `ViewerView.swift` | Visor a pantalla completa (reproduce vídeos; Espacio = reproducir/pausar) y `CompareView` (cortinilla antes/después; en vídeos, de un fotograma vía `MediaImage`) |
| `OptimizeView.swift` | Hoja de optimizar: ajustes de imagen (`OptimizeSettingsForm`) o de vídeo (`VideoSettingsForm`), selector Imágenes/Vídeos en lotes mixtos, `SaveSettings` común, resultados, comparador, guardar |
| `SettingsPane.swift` | Ubicación de la biblioteca (`LibraryLocationCard`: iCloud Drive, otra carpeta, por defecto), idioma, actualizaciones, estado de las herramientas |
| `Clipboard.swift` | «Copiar»: un elemento con la URL del archivo, sus bytes con su tipo y un PNG, para que pegue tanto en el Finder como en navegadores y documentos (vídeos: solo la URL) |
| `Settings.swift` | `UserDefaults` (`com.egluu.demoimages`): opciones de optimización de imagen (`optimizeOptions`) y de vídeo (`optimizeVideoOptions`), orden, tamaño de miniatura |
| `Icon/AppIcon.html` | Fuente del icono (diseño A, «Foto sobre cuadros»). `scripts/make-icon.sh` lo renderiza con Chrome headless y genera `Resources/AppIcon.icns` (versionado; `build-app.sh` lo copia al bundle) e `Icon/AppIcon-1024.png` |
| `Theme.swift` | Colores y controles comunes (estilo oscuro de Wallpy) |
| `Updater.swift` | Autoactualización desde GitHub Releases con SHA-256 |
| `Localization.swift` | Idiomas (en, es, ca): `tr()`, `Localizer`, tablas |

Datos: `<raíz>/{library.json,Albums/<uuid>/}`. La raíz es `Library.defaultRoot` (`~/Library/Application Support/DemoImages`) o la elegida en Ajustes (clave `libraryPath` en `UserDefaults`; `Library.move(to:)` traslada, `Library.open(_:)` abre otra sin mover). iCloud Drive: `~/Library/Mobile Documents/com~apple~CloudDocs/DemoImages`. Temporales: `$TMPDIR/DemoImages-*` (se borran al cerrar la hoja de optimizar y los que tengan más de 12 h al arrancar).

## Convenciones

- Código, comentarios y commits en inglés. Interfaz en castellano, inglés y catalán.
- **Todo texto visible pasa por `tr("…")`** (o `tr("… %@ …", arg)`). La clave es el texto en castellano; añadir la traducción a `en` y `ca` en `Localization.swift` con los mismos `%@`/`%d`. Nunca interpolar dentro de un texto traducible. Los nombres de formato (WebP, AVIF, HEVC…) no se traducen. Los contadores dicen «elementos» si el álbum tiene vídeos e «imágenes» si no; cada variante con su `tr("…")` literal (el CI no ve claves dinámicas).
- Estilo: usar `Theme` y sus componentes (`AppButtonStyle`, `SmallButton`, `SegmentedControl`, `SwitchRow`, `appCard`…), nunca colores sueltos.
- Estado de UI en tipos `@MainActor`; decodificar, codificar y copiar archivos fuera del hilo principal.
- Borrar = mover a la papelera (`trashItem`), nunca `removeItem` sobre imágenes del usuario.
- Mantener el README al día cuando cambian funciones visibles.

## Cosas que ya costaron (no repetir)

- **`NSHostingController` encoge la ventana**: `sizingOptions = []`, `setContentSize` y después `setFrameAutosaveName` (si se pone antes, la ventana queda a 900×600).
- **ImageIO no codifica WebP** (solo lo lee). AVIF sí en macOS recientes; se prefiere `avifenc` si está, por el control de esfuerzo.
- **MozJPEG es keg-only** en Homebrew: su `cjpeg` está en `$(brew --prefix)/opt/mozjpeg/bin`. El `cjpeg` de `bin/` es libjpeg-turbo; no usarlo como si fuera MozJPEG. Entrada en PPM (P6), que lee cualquier `cjpeg`.
- `UTType.avif` no existe en el SDK de macOS 14: usar `UTType.avifImage` (definido en `Optimizer.swift`).
- Builds universales (`--arch arm64 --arch x86_64`) necesitan Xcode completo (xcbuild); `build-app.sh` cae a la arquitectura nativa con solo CLT.
- **Biblioteca en iCloud (varios Mac)**: iCloud puede traer `library.json` antes que las imágenes, así que **nunca se quitan entradas porque falte su archivo** (la miniatura dice «Esperando a iCloud» y reintenta); solo a mano, en Ajustes («Quitar de la lista», `removeMissing`). Cada cambio local queda anotado (`localAdded` / `localDeleted` / `localModified`) y `save()`, si el índice cambió en disco desde la última lectura, fusiona: lo tocado aquí gana, lo demás sigue al disco. Lectura y escritura con `NSFileCoordinator`. Con la biblioteca en iCloud y la app activa se comprueba la fecha de `library.json` cada 3 s (`startWatching`), y también al activarse la app.
- **Versiones optimizadas**: `ImageItem.sourceID` apunta al original (mismo álbum) y `ImageItem.optimization` (`OptimizationInfo`) guarda formato, ajustes y tamaño de partida. Campos opcionales: un `library.json` antiguo se sigue leyendo. `OptimizationInfo.codecID` es texto, no `Codec`, para que un formato futuro no rompa la decodificación. Con «Agrupar versiones» (por defecto) la galería solo muestra originales y las acciones sobre un original incluyen sus versiones (`withVersions`). Copiar entre álbumes da ids nuevos y reenlaza (`transfer`); «Reemplazar» conserva el id, así las versiones siguen enlazadas.
- **Runners de GitHub**: `macos-14` ya no existe («configuration … is not supported»). En `macos-15` el job puede quedarse en cola hasta que GitHub lo cancela por capacidad; no es un fallo del código: relanzar con `gh run rerun <id>`.
- **Vídeos**: son `ImageItem` con `duration` (opcional; `isVideo`). Solo entra lo que AVFoundation lee (WebM y MKV se rechazan al importar). `Library.makeItem` es síncrono, así que lee el vídeo con `VideoFile.infoBlocking` (semáforo sobre la API async). Los presets de exportación no agrandan y HEVC solo tiene original, 4K y 1080p. `NSImage(cgImage:size:)` da un rep con los píxeles duplicados en Retina: para fotogramas usar `NSBitmapImageRep(cgImage:)` (el 1:1 del comparador depende de eso). `AVPlayerView` se subclasifica sin `acceptsFirstResponder` para que el visor conserve las teclas. Al copiar un vídeo al portapapeles solo va la URL del archivo (no sus bytes).
- **Optimizar vídeos**: `OptimizationInfo.codecID` es `hevc` / `h264` (`title` resuelve el nombre para imagen y vídeo) y `detail` guarda la resolución («1080p»). La hoja no empieza sola con vídeos (pueden tardar minutos) y codifica como mucho 2 a la vez. `build-app.sh` declara `public.movie` en `CFBundleDocumentTypes` para «Abrir con».
- `main.swift` envuelve el arranque en `MainActor.assumeIsolated` porque `AppDelegate` es `@MainActor`.

## Pruebas manuales

- No hay permiso de grabación de pantalla: `screencapture -l` falla. Para comprobar ventanas, `CGWindowListCopyWindowInfo` filtrando por propietario `DemoImages`; para comprobar datos, leer `library.json`.
- Para probar sin tocar la biblioteca del usuario (está en iCloud): crear una carpeta con un `library.json` de un álbum vacío y lanzar `open -n -a build/DemoImages.app archivo.mp4 --args -libraryPath <carpeta> -lastAlbumID <uuid>`; después `defaults import` de la copia, porque `lastAlbumID` y el marco de la ventana sí se escriben.
- La biblioteca del usuario puede tener imágenes suyas: si una prueba la toca, copiar antes `~/Library/Application Support/DemoImages` y `defaults export com.egluu.demoimages`, y restaurarlos después.
