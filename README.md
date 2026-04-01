# HandWriter ✍️

App multipiattaforma per prendere appunti a mano e a testo, con sincronizzazione diretta su Nextcloud via WebDAV.

## Stack Tecnologico

| Componente | Tecnologia | Motivazione |
|-----------|-----------|-------------|
| Framework | **Flutter 3.x** | Canvas nativo via Skia/Impeller, 95%+ code sharing |
| State Management | **Riverpod** | Type-safe, testabile, dependency injection |
| Data Models | **Freezed + json_serializable** | Immutabili, serializzazione automatica |
| WebDAV | **webdav_client** | Protocollo standard per Nextcloud |
| Storage Locale | **SQLite (sqflite)** | Cache offline-first |
| Canvas | **CustomPainter + Skia** | Rendering GPU-accelerato, <16ms latenza |

## Perché Flutter e non Tauri/React?

1. **Performance canvas**: Flutter usa Skia (e Impeller su iOS) per rendering GPU diretto. Un canvas HTML/WebGL ha overhead di bridging e non può eguagliare la latenza di un `CustomPainter` nativo.
2. **Stylus support**: Flutter espone `PointerEvent` con `pressure`, `tilt`, `orientation` nativamente su tutte le piattaforme.
3. **Single codebase**: 95% del codice condiviso tra iOS, Android, macOS, Windows, Linux e Web.
4. **Mature ecosystem**: Package come `flutter_quill`, `perfect_freehand` (per simulazione pressione) sono già disponibili.

## Formato File .ncnote

Un file `.ncnote` è un **archivio ZIP rinominato** con questa struttura:

```
notebook.ncnote
├── metadata.json          # Info taccuino
├── document.json          # Struttura documento e pagine
├── pages/
│   ├── page_001.json      # Dati vettoriali pagina 1
│   ├── page_002.json      # Dati vettoriali pagina 2
│   └── ...
├── assets/
│   ├── images/            # Immagini incorporate
│   └── pdfs/              # PDF di base per annotazione
└── thumbnails/
    ├── cover.png           # Anteprima copertina
    └── page_001.png        # Thumbnail pagina 1
```

## Setup Rapido

```bash
# Prerequisiti: Flutter >= 3.19
flutter doctor

# Setup progetto
cd handwriter
chmod +x init.sh && ./init.sh

# Configura Nextcloud in lib/config/app_config.dart
# poi:
dart run build_runner build --delete-conflicting-outputs
flutter run
```

## Architettura

```
lib/
├── main.dart                           # Entry point
├── config/
│   └── app_config.dart                 # Configurazione centralizzata
├── core/
│   └── services/
│       ├── webdav_service.dart          # Client WebDAV
│       └── sync_service.dart           # Engine sync offline-first
├── features/
│   └── canvas/
│       └── data/
│           └── render_engine.dart       # CustomPainter ottimizzato
└── shared/
    └── models/
        └── ncnote_format.dart          # Modelli dati Freezed
```

## Roadmap

- **Fase 1** ✅ Architettura, formato file, WebDAV, canvas engine base
- **Fase 2** 🔜 UI Canvas, toolbar, gesture recognition
- **Fase 3** Stylus avanzato (pressione, tilt), palm rejection
- **Fase 4** PDF import, shape recognition, OCR
- **Fase 5** Sicurezza (secure storage, certificate pinning)
- **Fase 6** Polish, performance tuning, release

## Licenza

Progetto privato.
