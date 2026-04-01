# Formato File .ncnote — Specifica Tecnica

## Panoramica

Un file `.ncnote` è un **archivio ZIP rinominato**. Può essere aperto con qualsiasi tool ZIP per ispezione manuale.

## Struttura

```
my_notebook.ncnote (ZIP)
│
├── metadata.json           # Metadati del taccuino
├── document.json           # Indice delle pagine
│
├── pages/
│   ├── page_001.json       # Dati vettoriali pagina 1
│   ├── page_002.json       # Dati vettoriali pagina 2
│   └── ...
│
├── assets/
│   ├── images/
│   │   ├── img_abc123.png  # Immagini incorporate
│   │   └── ...
│   └── pdfs/
│       └── base_doc.pdf    # PDF di base per annotazione
│
└── thumbnails/
    ├── cover.png           # Anteprima copertina (256x256)
    └── page_001.png        # Thumbnail pagina (256x362)
```

## metadata.json

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "title": "Appunti di Fisica",
  "formatVersion": 1,
  "createdAt": "2026-03-31T10:00:00Z",
  "modifiedAt": "2026-03-31T15:30:00Z",
  "coverStyle": "default",
  "coverColor": 1432809408,
  "paperType": "grid",
  "paperColor": 4294967295,
  "pageCount": 42,
  "tags": ["università", "fisica", "2026"],
  "author": "Mario Rossi",
  "description": "Appunti del corso di Fisica 2"
}
```

## document.json

```json
{
  "notebookId": "550e8400-e29b-41d4-a716-446655440000",
  "formatVersion": 1,
  "pages": [
    {
      "pageId": "a1b2c3d4-...",
      "pageNumber": 1,
      "fileName": "page_001.json",
      "width": 595.0,
      "height": 842.0,
      "thumbnailFile": "page_001.png",
      "lastModified": "2026-03-31T15:30:00Z"
    }
  ]
}
```

## pages/page_001.json — Esempio completo

```json
{
  "pageId": "a1b2c3d4-...",
  "pageNumber": 1,
  "width": 595.0,
  "height": 842.0,
  "layers": {
    "background": {
      "type": "grid",
      "color": 4294967295,
      "lineSpacing": 25.0,
      "lineColor": 4292927712,
      "pdfAsset": null,
      "pdfPage": 0
    },
    "content": [
      {
        "type": "stroke",
        "id": "stroke-001",
        "zIndex": 0,
        "data": {
          "points": [
            {"x": 100.0, "y": 200.0, "pressure": 0.3, "tilt": 0.0, "timestamp": 0},
            {"x": 105.2, "y": 198.1, "pressure": 0.45, "tilt": 0.1, "timestamp": 8},
            {"x": 112.8, "y": 195.3, "pressure": 0.6, "tilt": 0.1, "timestamp": 16},
            {"x": 124.1, "y": 190.2, "pressure": 0.75, "tilt": 0.15, "timestamp": 24},
            {"x": 138.5, "y": 188.0, "pressure": 0.8, "tilt": 0.1, "timestamp": 32}
          ],
          "toolType": "pen",
          "color": 4278190080,
          "baseWidth": 2.5,
          "isHighlighter": false,
          "opacity": 1.0,
          "timestamp": "2026-03-31T15:28:00Z"
        }
      },
      {
        "type": "text",
        "id": "text-001",
        "zIndex": 1,
        "data": {
          "x": 50.0,
          "y": 50.0,
          "width": 400.0,
          "height": 30.0,
          "content": "Capitolo 3: Termodinamica",
          "fontFamily": "sans-serif",
          "fontSize": 22.0,
          "color": 4281545523,
          "bold": true,
          "italic": false,
          "alignment": "left"
        }
      },
      {
        "type": "shape",
        "id": "shape-001",
        "zIndex": 2,
        "data": {
          "shapeType": "rectangle",
          "x1": 300.0,
          "y1": 400.0,
          "x2": 500.0,
          "y2": 500.0,
          "strokeColor": 4278190335,
          "strokeWidth": 2.0,
          "fillColor": null,
          "rotation": 0.0
        }
      },
      {
        "type": "image",
        "id": "img-001",
        "zIndex": 3,
        "data": {
          "x": 100.0,
          "y": 550.0,
          "width": 200.0,
          "height": 150.0,
          "assetPath": "images/img_abc123.png",
          "rotation": 0.0,
          "opacity": 1.0
        }
      }
    ]
  },
  "assetReferences": ["images/img_abc123.png"],
  "createdAt": "2026-03-31T10:00:00Z",
  "modifiedAt": "2026-03-31T15:30:00Z"
}
```

## Note sul Design

### Coordinate
- Origine (0,0) in alto a sinistra
- Unità: punti (1 punto = 1/72 pollice)
- A4: 595 x 842 punti

### Pressione
- Range: 0.0 (nessun contatto) — 1.0 (massima pressione)
- Default 0.5 per input senza rilevamento pressione (mouse)

### Colori
- Formato: intero ARGB (es. `0xFF1565C0` = Blue 800)
- Alpha nel byte più significativo

### Timestamp nei punti
- Millisecondi relativi dall'inizio del tratto
- Usati per replay e analisi velocità

### Compressione
- ZIP con deflate standard
- I JSON non vengono pre-compressi (ZIP li comprime già bene)
- Le immagini PNG/JPEG restano nel loro formato nativo
