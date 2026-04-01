# Architettura HandWriter

## Panoramica

```
┌─────────────────────────────────────────────┐
│                   UI Layer                   │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐ │
│  │ Library  │  │  Canvas  │  │ Settings  │ │
│  │  Screen  │  │  Screen  │  │  Screen   │ │
│  └────┬─────┘  └────┬─────┘  └─────┬─────┘ │
├───────┴──────────────┴──────────────┴───────┤
│              State Management                │
│              (Riverpod Providers)             │
├──────────────────────────────────────────────┤
│              Business Logic                  │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐ │
│  │  Sync    │  │  File    │  │  Canvas   │ │
│  │ Service  │  │ Service  │  │  Engine   │ │
│  └────┬─────┘  └────┬─────┘  └───────────┘ │
├───────┴──────────────┴──────────────────────┤
│              Data Layer                      │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐ │
│  │  WebDAV  │  │  SQLite  │  │   File    │ │
│  │  Client  │  │  Cache   │  │   I/O     │ │
│  └──────────┘  └──────────┘  └───────────┘ │
├──────────────────────────────────────────────┤
│            Nextcloud Server (WebDAV)         │
└──────────────────────────────────────────────┘
```

## Decisioni Architetturali

### 1. Offline-First

Ogni operazione scrive prima in locale (SQLite + file system), poi sincronizza in background con Nextcloud. Questo garantisce:
- Latenza zero per l'utente
- Funzionamento senza rete
- Conflict resolution via last-write-wins con backup del conflitto

### 2. Layer-Based Rendering

Il canvas usa un sistema a 3 layer:
- **Background Layer**: griglia, righe, sfondo pagina
- **Content Layer**: tratti, testo, immagini, forme
- **UI Layer**: selezione lazo, cursore, guide

Ogni layer è un `CustomPainter` separato, permettendo di re-renderizzare solo il layer modificato (es. solo content quando si disegna, senza ridisegnare lo sfondo).

### 3. Modello Dati Immutabile

Tutti i modelli usano `Freezed` per garantire immutabilità. Le modifiche creano nuove istanze via `copyWith()`, facilitando:
- Undo/Redo (stack di stati)
- Debugging (ogni stato è tracciabile)
- Thread safety

### 4. Formato .ncnote Paginato

Ogni pagina è un file JSON separato dentro il pacchetto ZIP. Vantaggi:
- Si carica solo la pagina visibile (lazy loading)
- Si sincronizza solo la pagina modificata (delta sync)
- Parallelismo nel caricamento

### 5. Interpolazione Catmull-Rom

I tratti raw del pennino vengono lisciati con spline Catmull-Rom per ottenere curve fluide. La pressione viene interpolata linearmente tra i punti per variare lo spessore del tratto.

## Flusso Dati: Scrittura di un Tratto

```
1. PointerDown/Move event (con pressure, tilt)
   ↓
2. StrokeCollector accumula punti raw
   ↓
3. Catmull-Rom interpolation (smoothing)
   ↓
4. RenderEngine.paintStroke() → Canvas
   ↓
5. StrokeData aggiunto al PageModel (Freezed copyWith)
   ↓
6. Riverpod notifica UI
   ↓
7. SyncService.markDirty(pageId) → SQLite queue
   ↓
8. Background: FileService salva page_XXX.json
   ↓
9. Background: SyncService.upload() → WebDAV PUT
```

## Flusso Dati: Apertura Notebook

```
1. User tap su notebook in Library
   ↓
2. Check cache locale (SQLite metadata)
   ↓
3a. Cache hit + fresh → Apri da file system locale
3b. Cache miss/stale → WebDAV GET .ncnote
   ↓
4. Decomprimi ZIP → estrai metadata.json + page corrente
   ↓
5. Deserializza PageModel (Freezed fromJson)
   ↓
6. RenderEngine renderizza layer
   ↓
7. Prefetch pagine adiacenti in background
```

## Gestione Conflitti

```
Se ETag remoto ≠ ETag locale salvato:
  1. Scarica versione remota
  2. Salva come notebook_conflict_<timestamp>.ncnote
  3. Applica versione locale (last-write-wins)
  4. Notifica utente del conflitto
  5. User può confrontare e risolvere manualmente
```

## Performance Targets

| Metrica | Target | Come |
|---------|--------|------|
| Stroke latency | <16ms | CustomPainter diretto, no widget rebuild |
| FPS durante scrittura | 60fps | RepaintBoundary, layer separation |
| Apertura notebook | <500ms | Lazy page loading, cache locale |
| Sync incrementale | <1s per pagina | Delta sync per singola pagina |
| RAM per notebook | <100MB | Pagine non visibili deallocate |
