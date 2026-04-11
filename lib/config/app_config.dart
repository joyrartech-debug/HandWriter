/// Configurazione centralizzata dell'app HandWriter.
class AppConfig {
  // ── App Version ──
  // Bump this version for each prompt-driven modification.
  static const String appVersion = '0.30.0';

  // ── WebDAV / Nextcloud ──
  static const String defaultRemotePath = '/HandWriter/';
  static const int webdavTimeoutSeconds = 30;
  static const int maxRetries = 3;

  // ── Sync ──
  static const Duration syncDebounce = Duration(seconds: 5);
  static const Duration syncInterval = Duration(minutes: 5);
  static const int maxConcurrentSyncs = 3;

  // ── Canvas ──
  static const double defaultStrokeWidth = 2.0;
  static const double minStrokeWidth = 0.5;
  static const double maxStrokeWidth = 20.0;
  static const double pressureSensitivity = 1.0;
  static const int catmullRomSegments = 4; // punti interpolati tra 2 raw
  static const double defaultPageWidth = 595.0; // A4 in punti (72dpi)
  static const double defaultPageHeight = 842.0;

  // ── File Format ──
  static const String fileExtension = '.ncnote';
  static const String metadataFile = 'metadata.json';
  static const String documentFile = 'document.json';
  static const String pagesDir = 'pages';
  static const String assetsDir = 'assets';
  static const String thumbnailsDir = 'thumbnails';
  static const int formatVersion = 1;

  // ── Cache ──
  static const int maxCachedPages = 10; // pagine in memoria
  static const Duration cacheExpiry = Duration(hours: 24);
  static const int maxThumbnailCacheSize = 50; // MB

  // ── Database ──
  static const String dbName = 'handwriter.db';
  static const int dbVersion = 1;
}
