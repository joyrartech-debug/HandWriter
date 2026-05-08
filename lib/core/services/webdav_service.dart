import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as http_io;
import 'package:xml/xml.dart';
import 'package:handwriter/config/app_config.dart';

/// Informazioni su un file/cartella remoto WebDAV.
class WebDavItem {
  final String path;
  final String name;
  final bool isDirectory;
  final int? contentLength;
  final String? etag;
  final DateTime? lastModified;
  final String? contentType;

  WebDavItem({
    required this.path,
    required this.name,
    required this.isDirectory,
    this.contentLength,
    this.etag,
    this.lastModified,
    this.contentType,
  });
}

/// Client WebDAV per connessione diretta a Nextcloud.
///
/// Supporta: PROPFIND (listing), GET (download), PUT (upload),
/// MKCOL (crea cartella), DELETE.
class WebDavService {
  /// Parallel-connection limit per host.
  ///
  /// Dart's default `HttpClient.maxConnectionsPerHost` is 6 — matching the
  /// old HTTP/1.1 browser convention.  For a delta pull that fires 30
  /// page downloads with `Future.wait`, that means 6 active + 24 queued
  /// and the whole batch takes ceil(30/6) = 5 RTTs minimum instead of 1.
  ///
  /// Bumping to 16 gives a solid 2–3× speedup on parallel pulls on both
  /// desktop (low RTT, CPU-bound) and mobile/Tailscale (higher RTT,
  /// latency-bound) without overwhelming a typical Nextcloud server.
  /// Raising further hits diminishing returns (server-side worker pool
  /// + TCP slow-start dominate).
  static const int _maxConnectionsPerHost = 16;

  /// How long an idle connection is held open before the client drops it.
  /// Longer keep-alive means fewer TCP+TLS handshakes during the 4-second
  /// polling loop; too long and mobile OSes start complaining about
  /// battery.
  static const Duration _idleTimeout = Duration(seconds: 45);

  final String serverUrl;
  final String username;
  final String password;
  final String basePath;

  late final String _davUrl;
  late final Map<String, String> _authHeaders;
  late http.Client _client;
  late io.HttpClient _innerHttpClient;

  /// Counter of consecutive request failures (timeout, IO error, null
  /// response where we expected content). When this exceeds
  /// [_zombieClientThreshold] we rebuild the underlying HttpClient — on
  /// iOS the NSURLSession backing dart:io can occasionally get into a
  /// state where EVERY outbound call returns null/empty even though the
  /// network itself is healthy (verified by Safari), and only a fresh
  /// session fixes it. Resets on every successful request.
  int _consecutiveFailures = 0;
  static const int _zombieClientThreshold = 3;
  DateTime _lastClientBuildAt = DateTime.now();
  /// Minimum time between rebuilds so a legitimate server outage doesn't
  /// spin us into a tight reconnect loop.
  static const Duration _clientRebuildCooldown = Duration(seconds: 20);

  WebDavService({
    required this.serverUrl,
    required this.username,
    required this.password,
    this.basePath = AppConfig.defaultRemotePath,
  }) {
    // Warn if not using HTTPS (credentials travel in plaintext over HTTP)
    final uri = Uri.parse(serverUrl);
    if (uri.scheme != 'https') {
      // ignore: avoid_print
      print('[WebDAV] WARNING: Connection uses HTTP — credentials are not encrypted. '
          'Consider switching to HTTPS.');
    }

    // Nextcloud WebDAV endpoint standard
    final cleanUrl = serverUrl.replaceAll(RegExp(r'/+$'), '');
    _davUrl = '$cleanUrl/remote.php/dav/files/$username';

    final credentials = base64Encode(utf8.encode('$username:$password'));
    _authHeaders = {
      'Authorization': 'Basic $credentials',
      // Explicit gzip request so Nextcloud's mod_deflate compresses the
      // JSON page payloads on the wire — typical compression ratio for
      // stroke JSON is 5-10× so this is a significant bandwidth saving
      // on slower links (Tailscale over cellular).  Dart's HttpClient
      // auto-decompresses gzip responses by default.
      'Accept-Encoding': 'gzip',
    };

    _buildClient();

    // Pre-warm the connection pool in the background so the very first
    // pull on app-start doesn't pay the TCP handshake / TLS ALPN cost
    // inside the user's "Apertura notebook..." dialog.  Fire-and-forget;
    // a failure here just means the first real request pays the cost.
    // ignore: discarded_futures
    _preWarm();
  }

  void _buildClient() {
    // Tear down any previous HttpClient (on reconnect / zombie recovery).
    try { _client.close(); } catch (_) {}
    _innerHttpClient = io.HttpClient()
      ..maxConnectionsPerHost = _maxConnectionsPerHost
      ..idleTimeout = _idleTimeout
      ..autoUncompress = true
      ..badCertificateCallback = _badCertificateCallback;
    _client = http_io.IOClient(_innerHttpClient);
    _lastClientBuildAt = DateTime.now();
    _consecutiveFailures = 0;
  }

  /// Record a request outcome. On repeated failure, rebuild the underlying
  /// HttpClient to recover from an iOS NSURLSession that has silently
  /// gone zombie (Safari works, dart:io returns null for every call).
  void _recordSuccess() {
    if (_consecutiveFailures > 0) {
      // ignore: avoid_print
      print('[WebDAV] Recovered after $_consecutiveFailures consecutive failures');
    }
    _consecutiveFailures = 0;
  }

  void _recordFailure(String op, Object error) {
    _consecutiveFailures++;
    final sinceBuild = DateTime.now().difference(_lastClientBuildAt);
    if (_consecutiveFailures >= _zombieClientThreshold &&
        sinceBuild > _clientRebuildCooldown) {
      // ignore: avoid_print
      print('[WebDAV] Rebuilding HttpClient after $_consecutiveFailures '
          'consecutive failures on $op: $error');
      _buildClient();
      // fire-and-forget pre-warm on the fresh client
      // ignore: discarded_futures
      _preWarm();
    }
  }

  /// Force-rebuild the HttpClient. Call this when connectivity is known
  /// to have transitioned offline→online (iOS can leave NSURLSession
  /// stranded after a Tailscale/WiFi handoff; Safari works but our
  /// dart:io client keeps returning null). The rebuild cooldown is
  /// bypassed because the caller has external evidence of a transition.
  void wakeUp() {
    // ignore: avoid_print
    print('[WebDAV] wakeUp() — rebuilding HttpClient on external trigger');
    _buildClient();
    // ignore: discarded_futures
    _preWarm();
  }

  bool _badCertificateCallback(io.X509Certificate cert, String host, int port) {
    // Scope: only trust self-signed certs for the server host the user
    // explicitly configured in credentials.  Anything else (random HTTPS
    // calls made accidentally) stays strict.
    final configured = Uri.parse(serverUrl);
    return host == configured.host &&
        (configured.scheme == 'https');
  }

  Future<void> _preWarm() async {
    try {
      final r = await _client
          .head(Uri.parse(_fullUrl('/')), headers: _authHeaders)
          .timeout(const Duration(seconds: 5));
      // Drain to release connection back to the pool.
      // ignore: avoid_print
      print('[WebDAV] Connection pre-warmed (status ${r.statusCode})');
    } catch (_) {
      // Silently ignore — first real request will retry with normal timeout.
    }
  }

  /// URL completo per un path remoto.
  String _fullUrl(String remotePath) {
    final cleanPath = remotePath.startsWith('/') ? remotePath : '/$remotePath';
    return '$_davUrl$cleanPath';
  }

  /// Testa la connessione al server Nextcloud.
  /// Ritorna true se autenticazione e accesso riusciti.
  Future<bool> testConnection() async {
    try {
      final response = await _client
          .send(http.Request('PROPFIND', Uri.parse(_fullUrl('/')))
            ..headers.addAll({
              ..._authHeaders,
              'Depth': '0',
              'Content-Type': 'application/xml',
            }))
          .timeout(const Duration(seconds: AppConfig.webdavTimeoutSeconds));

      return response.statusCode == 207; // Multi-Status = successo
    } catch (e) {
      return false;
    }
  }

  /// Lista file e cartelle in un path remoto.
  Future<List<WebDavItem>> listDirectory(String remotePath) async {
    try {
      final request = http.Request('PROPFIND', Uri.parse(_fullUrl(remotePath)));
      request.headers.addAll({
        ..._authHeaders,
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
      });
      request.body = '''<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:resourcetype/>
    <d:getcontentlength/>
    <d:getetag/>
    <d:getlastmodified/>
    <d:getcontenttype/>
  </d:prop>
</d:propfind>''';

      final streamedResponse = await _client
          .send(request)
          .timeout(const Duration(seconds: AppConfig.webdavTimeoutSeconds));

      if (streamedResponse.statusCode == 404) {
        _recordSuccess(); // genuine not-found, not a client health issue
        throw WebDavException('PROPFIND 404', 404);
      }
      if (streamedResponse.statusCode != 207) {
        _recordFailure('listDirectory', 'status ${streamedResponse.statusCode}');
        throw WebDavException(
          'PROPFIND failed: ${streamedResponse.statusCode}',
          streamedResponse.statusCode,
        );
      }

      final body = await streamedResponse.stream.bytesToString();
      _recordSuccess();
      return _parseMultiStatus(body, remotePath);
    } on WebDavException {
      rethrow;
    } catch (e) {
      _recordFailure('listDirectory', e);
      rethrow;
    }
  }

  /// Scarica un file dal server.
  ///
  /// [timeoutSeconds] overrides the default; pass a larger value for known-
  /// big files (root .ncnote ZIPs in particular).  Default `null` falls
  /// back to the general WebDAV timeout — fine for most page/asset GETs.
  ///
  /// Post-GET integrity check: if the server sends a `Content-Length`
  /// header we compare it against `bodyBytes.length` and reject mismatches.
  /// Observed in the wild: Nextcloud over a Tailscale relay occasionally
  /// returns a partial body (truncated at a 1024- or 65536-byte buffer
  /// boundary) with status 200. `package:http` does NOT raise for that —
  /// it just hands back the short buffer. Without verification the caller
  /// (a delta pull, a JSON parse, a PNG decoder) blows up downstream and
  /// on `metadata.json` the entire pull aborts mid-way, so
  /// `_lastPageEtags` never advances and the next pull cycle restarts
  /// the same 300-page download forever. We retry up to
  /// [_downloadMaxAttempts] times with exponential backoff before
  /// surfacing a [WebDavTruncatedDownloadException].
  ///
  /// When [criticalVerify] is true (used for `metadata.json` /
  /// `document.json`, the two files whose corruption aborts the entire
  /// pull) we additionally PROPFIND the file when the response had no
  /// `Content-Length` header — Nextcloud routinely sends chunked
  /// responses, which means the cheap header check is null even though
  /// the body was silently cut mid-stream. The +1 RTT is well worth it:
  /// without this, a single bad metadata download wedges the notebook
  /// in the 0-of-N pull loop forever.
  Future<Uint8List> downloadFile(String remotePath,
      {int? timeoutSeconds, bool criticalVerify = false}) async {
    Object? lastError;
    for (var attempt = 0; attempt < _downloadMaxAttempts; attempt++) {
      try {
        final response = await _client
            .get(
              Uri.parse(_fullUrl(remotePath)),
              headers: _authHeaders,
            )
            .timeout(Duration(
                seconds: timeoutSeconds ?? AppConfig.webdavTimeoutSeconds));

        if (response.statusCode == 404) {
          _recordSuccess();
          throw WebDavException('GET 404', 404);
        }
        if (response.statusCode != 200) {
          _recordFailure('downloadFile', 'status ${response.statusCode}');
          throw WebDavException(
            'GET failed: ${response.statusCode}',
            response.statusCode,
          );
        }

        final bytes = response.bodyBytes;

        // Detect gzipped responses. dart:io decompresses transparently
        // (autoUncompress=true) but does NOT update the Content-Length
        // header — it still reflects the *compressed* wire size, while
        // bodyBytes contains decompressed bytes. Documented explicitly in
        // dart:io HttpClientResponseCompressionState: "Content-Length
        // cannot be trusted [when decompressed]". Comparing them blindly
        // would throw WebDavTruncatedDownloadException on EVERY successful
        // gzipped JSON download. Skip the header check in that case.
        final encoding = (response.headers['content-encoding'] ?? '')
            .toLowerCase();
        final isDecompressed = encoding.contains('gzip') ||
            encoding.contains('deflate') || encoding.contains('br');
        final declared = response.contentLength;
        int? expectedSize =
            (isDecompressed || declared == null) ? null : declared;

        // criticalVerify (metadata.json / document.json): always confirm
        // via PROPFIND. The header check above can't be trusted under
        // gzip and Nextcloud frequently chunks these — without an
        // independent size source a truncated GET sneaks past as a valid
        // (parseable up to the cut) JSON and then strands _lastPageEtags
        // forever. +1 RTT for these two files is a fair price.
        if (criticalVerify) {
          try {
            final propfindSize = await getContentLength(remotePath)
                .timeout(const Duration(seconds: 10));
            if (propfindSize != null) expectedSize = propfindSize;
          } catch (e) {
            // ignore: avoid_print
            print('[WebDAV] downloadFile critical-verify: PROPFIND failed '
                'for $remotePath: $e — trusting body');
          }
        }

        if (expectedSize != null && expectedSize != bytes.length) {
          // ignore: avoid_print
          print('[WebDAV] downloadFile TRUNCATED $remotePath: '
              'expected ${expectedSize}B, received ${bytes.length}B '
              '(diff ${expectedSize - bytes.length}B) — retry attempt '
              '${attempt + 1}/$_downloadMaxAttempts');
          _recordFailure('downloadFile',
              'truncated ${bytes.length}/$expectedSize');
          lastError = WebDavTruncatedDownloadException(
              remotePath, expectedSize, bytes.length);
          if (attempt < _downloadMaxAttempts - 1) {
            await Future.delayed(
                Duration(milliseconds: 400 * (1 << attempt)));
            continue;
          }
          throw lastError as WebDavTruncatedDownloadException;
        }

        _recordSuccess();
        return bytes;
      } on WebDavTruncatedDownloadException {
        rethrow;
      } on WebDavException {
        rethrow;
      } catch (e) {
        _recordFailure('downloadFile', e);
        rethrow;
      }
    }
    throw lastError ?? StateError('downloadFile: exhausted attempts');
  }

  static const int _downloadMaxAttempts = 3;

  /// Carica un file sul server. Crea o sovrascrive.
  /// Ritorna l'ETag della nuova versione.
  /// [timeoutSeconds] overrides the default timeout for this call.
  ///
  /// Post-PUT integrity check: after every successful PUT we re-read the
  /// remote `getcontentlength` via PROPFIND and compare it against
  /// `data.length`. This catches the silent-truncation scenario where the
  /// HTTP layer reports 201/204 but the server actually committed a
  /// partial body (observed: large stroke pages frozen at 256 KB or
  /// other 1024-byte aligned offsets after an interrupted iOS background
  /// PUT or a Tailscale stall). On mismatch we retry the upload with
  /// exponential backoff; if every attempt produces a short body we
  /// throw [WebDavSizeMismatchException] so the caller knows the server
  /// state is poisoned and can heal it (or surface the error) — this is
  /// strictly better than silently leaving truncated bytes on the
  /// server, which causes downstream clients to fail forever with
  /// `FormatException` while pulling.
  ///
  /// The verification is skipped only for files small enough that no
  /// real-world HTTP buffer/proxy would truncate them ([_uploadVerifyMin]).
  Future<String?> uploadFile(String remotePath, Uint8List data,
      {int? timeoutSeconds, bool criticalVerify = false}) async {
    Object? lastError;
    for (var attempt = 0; attempt < _uploadMaxAttempts; attempt++) {
      try {
        final response = await _client.put(
          Uri.parse(_fullUrl(remotePath)),
          headers: {
            ..._authHeaders,
            'Content-Type': 'application/octet-stream',
          },
          body: data,
        ).timeout(Duration(seconds: timeoutSeconds ?? AppConfig.webdavTimeoutSeconds));

        if (response.statusCode != 201 && response.statusCode != 204) {
          _recordFailure('uploadFile', 'status ${response.statusCode}');
          throw WebDavException(
            'PUT failed: ${response.statusCode}',
            response.statusCode,
          );
        }

        // Post-PUT size verification. PROPFIND (not HEAD) so we read the
        // uncompressed on-disk byte count regardless of mod_deflate.
        // criticalVerify lowers the size gate to 0 — used for commit-marker
        // files (document.json, metadata.json) which can be just a few KB
        // but whose corruption breaks the whole notebook for every device.
        final verifyThreshold = criticalVerify ? 0 : _uploadVerifyMin;
        if (data.length >= verifyThreshold) {
          int? remoteSize;
          // PROPFIND verify with one in-place retry on failure for critical
          // files. Critical here means: keep retrying the *PROPFIND*, NOT
          // the PUT — re-PUTting a successfully-uploaded file just bumps
          // the ETag and triggers spurious pulls on every other device,
          // which on a flaky link spirals into cross-device ping-pong.
          // The PUT already happened; we only need to confirm the body.
          var verifyAttempts = criticalVerify ? 3 : 1;
          Object? verifyError;
          for (var v = 0; v < verifyAttempts; v++) {
            try {
              remoteSize = await getContentLength(remotePath)
                  .timeout(const Duration(seconds: 30));
              verifyError = null;
              break;
            } catch (e) {
              verifyError = e;
              if (v < verifyAttempts - 1) {
                await Future.delayed(
                    Duration(milliseconds: 500 * (1 << v)));
              }
            }
          }
          if (verifyError != null) {
            // ignore: avoid_print
            print('[WebDAV] uploadFile verify: PROPFIND failed for '
                '$remotePath: $verifyError — trusting PUT');
            _recordSuccess();
            // Nextcloud emits ETag wrapped in quotes per RFC 7232
            // (e.g. `"abc123"`). Every other reader (getEtagFast,
            // getEtag, page-etag harvest in syncDelta) strips them, so
            // returning the raw header here causes _remoteMetaEtag to
            // be persisted with quotes and mismatch every subsequent
            // poll's dequoted ETag → forces slow PROPFIND path forever.
            return response.headers['etag']?.replaceAll('"', '');
          }
          if (remoteSize != null && remoteSize != data.length) {
            // ignore: avoid_print
            print('[WebDAV] uploadFile SIZE MISMATCH on $remotePath: '
                'sent ${data.length}B, server has ${remoteSize}B '
                '(diff ${data.length - remoteSize}B) — retry attempt '
                '${attempt + 1}/$_uploadMaxAttempts');
            _recordFailure('uploadFile',
                'size mismatch ${data.length} vs $remoteSize');
            lastError = WebDavSizeMismatchException(
              remotePath, data.length, remoteSize);
            // Backoff before retry: 400ms, 1.2s.
            if (attempt < _uploadMaxAttempts - 1) {
              await Future.delayed(
                  Duration(milliseconds: 400 * (1 << attempt)));
              continue;
            }
            throw lastError as WebDavSizeMismatchException;
          }
        }

        _recordSuccess();
        return response.headers['etag']?.replaceAll('"', '');
      } on WebDavSizeMismatchException {
        rethrow;
      } on WebDavException {
        rethrow;
      } catch (e) {
        _recordFailure('uploadFile', e);
        rethrow;
      }
    }
    // Unreachable: loop either returns or throws.
    throw lastError ?? StateError('uploadFile: exhausted attempts');
  }

  /// Skip post-PUT verification under this size — too small to truncate
  /// in any realistic HTTP/proxy chain, and the PROPFIND round-trip would
  /// double the cost of metadata.json/document.json commits which fire on
  /// every save.
  static const int _uploadVerifyMin = 64 * 1024;
  static const int _uploadMaxAttempts = 3;

  /// Crea una cartella remota.
  Future<void> createDirectory(String remotePath) async {
    final request = http.Request('MKCOL', Uri.parse(_fullUrl(remotePath)));
    request.headers.addAll(_authHeaders);

    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: AppConfig.webdavTimeoutSeconds));

    if (response.statusCode != 201 && response.statusCode != 405) {
      // 405 = già esiste, OK
      throw WebDavException(
        'MKCOL failed: ${response.statusCode}',
        response.statusCode,
      );
    }
  }

  /// Elimina un file o cartella remota.
  Future<void> delete(String remotePath) async {
    final response = await _client.delete(
      Uri.parse(_fullUrl(remotePath)),
      headers: _authHeaders,
    ).timeout(const Duration(seconds: AppConfig.webdavTimeoutSeconds));

    if (response.statusCode != 204 && response.statusCode != 404) {
      throw WebDavException(
        'DELETE failed: ${response.statusCode}',
        response.statusCode,
      );
    }
  }

  /// Muove/rinomina un file o cartella remota.
  Future<void> move(String fromPath, String toPath) async {
    final request = http.Request('MOVE', Uri.parse(_fullUrl(fromPath)));
    request.headers.addAll({
      ..._authHeaders,
      'Destination': _fullUrl(toPath),
      'Overwrite': 'F',
    });

    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: AppConfig.webdavTimeoutSeconds));

    if (response.statusCode != 201 && response.statusCode != 204) {
      throw WebDavException(
        'MOVE failed: ${response.statusCode}',
        response.statusCode,
      );
    }
  }

  /// Ottieni ETag + Last-Modified di un file remoto in una sola PROPFIND.
  /// Usato dal sync per decidere chi vince in caso di conflitto (remote vs local).
  Future<({String? etag, DateTime? lastModified})?> getFileInfo(
      String remotePath) async {
    try {
      final request = http.Request('PROPFIND', Uri.parse(_fullUrl(remotePath)));
      request.headers.addAll({
        ..._authHeaders,
        'Depth': '0',
        'Content-Type': 'application/xml; charset=utf-8',
      });
      request.body = '''<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:getetag/>
    <d:getlastmodified/>
  </d:prop>
</d:propfind>''';

      final streamedResponse = await _client
          .send(request)
          .timeout(const Duration(seconds: AppConfig.webdavTimeoutSeconds));

      if (streamedResponse.statusCode != 207) return null;

      final body = await streamedResponse.stream.bytesToString();
      final document = XmlDocument.parse(body);
      String? etag;
      final etagEls = document.findAllElements('d:getetag');
      if (etagEls.isNotEmpty) {
        etag = etagEls.first.innerText.replaceAll('"', '');
      }
      DateTime? lastModified;
      final lmEls = document.findAllElements('d:getlastmodified');
      if (lmEls.isNotEmpty && lmEls.first.innerText.isNotEmpty) {
        lastModified = _parseHttpDate(lmEls.first.innerText);
      }
      return (etag: etag, lastModified: lastModified);
    } catch (_) {
      return null;
    }
  }

  /// Ottieni l'ETag di un file remoto (per conflict detection).
  Future<String?> getEtag(String remotePath) async {
    try {
      final request = http.Request('PROPFIND', Uri.parse(_fullUrl(remotePath)));
      request.headers.addAll({
        ..._authHeaders,
        'Depth': '0',
        'Content-Type': 'application/xml; charset=utf-8',
      });
      request.body = '''<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:getetag/>
  </d:prop>
</d:propfind>''';

      final streamedResponse = await _client
          .send(request)
          .timeout(const Duration(seconds: AppConfig.webdavTimeoutSeconds));

      if (streamedResponse.statusCode == 404) {
        // A genuine 404 is NOT a client-health failure — the file just
        // doesn't exist. Let callers distinguish via the thrown exception.
        _recordSuccess();
        throw WebDavException('PROPFIND 404', 404);
      }
      if (streamedResponse.statusCode != 207) {
        _recordFailure('getEtag', 'status ${streamedResponse.statusCode}');
        return null;
      }

      final body = await streamedResponse.stream.bytesToString();
      final document = XmlDocument.parse(body);
      final etagElements = document.findAllElements('d:getetag');
      if (etagElements.isEmpty) {
        _recordFailure('getEtag', 'empty response body');
        return null;
      }
      _recordSuccess();
      return etagElements.first.innerText.replaceAll('"', '');
    } on WebDavException {
      rethrow;
    } catch (e) {
      _recordFailure('getEtag', e);
      // Rethrow so callers (e.g. deltaFolderExists) can distinguish
      // 'network uncertainty' from 'definite 404'. The older 'return
      // null on any error' swallowed network issues and caused the
      // library to wipe local notebooks during Tailscale blips.
      rethrow;
    }
  }

  /// Assicura che la cartella base dell'app esista sul server.
  Future<void> ensureBaseDirectory() async {
    await createDirectory(basePath);
  }

  /// Ottieni la dimensione di un file remoto (Content-Length).
  /// Returns null if the file doesn't exist or size can't be determined.
  Future<int?> getContentLength(String remotePath) async {
    final request = http.Request('PROPFIND', Uri.parse(_fullUrl(remotePath)));
    request.headers.addAll({
      ..._authHeaders,
      'Depth': '0',
      'Content-Type': 'application/xml; charset=utf-8',
    });
    request.body = '''<?xml version="1.0" encoding="UTF-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:getcontentlength/>
  </d:prop>
</d:propfind>''';

    final streamedResponse = await _client
        .send(request)
        .timeout(const Duration(seconds: AppConfig.webdavTimeoutSeconds));

    if (streamedResponse.statusCode != 207) return null;

    final body = await streamedResponse.stream.bytesToString();
    final document = XmlDocument.parse(body);
    final clElements = document.findAllElements('d:getcontentlength');
    if (clElements.isEmpty || clElements.first.innerText.isEmpty) return null;
    return int.tryParse(clElements.first.innerText);
  }

  /// Fast ETag check via HEAD — single request, no XML parse.
  /// Falls back to null on any error (caller retries via PROPFIND).
  /// Feeds the zombie-client detector: repeated nulls rebuild the client.
  Future<String?> getEtagFast(String remotePath) async {
    try {
      final response = await _client.head(
        Uri.parse(_fullUrl(remotePath)),
        headers: _authHeaders,
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        _recordFailure('getEtagFast', 'status ${response.statusCode}');
        return null;
      }
      final etag = response.headers['etag'];
      if (etag == null) {
        // HEAD succeeded status-wise but response missing headers is the
        // classic 'zombie client' symptom on iOS NSURLSession.
        _recordFailure('getEtagFast', 'missing etag header');
        return null;
      }
      _recordSuccess();
      return etag.replaceAll('"', '');
    } catch (e) {
      _recordFailure('getEtagFast', e);
      return null;
    }
  }

  /// Parsa la risposta XML Multi-Status di PROPFIND.
  ///
  /// Robusto contro risposte malformate (server buggati, proxy che alterano
  /// il namespace, propstat con status != 200): ogni entry che non espone i
  /// campi attesi viene semplicemente saltata invece di far esplodere
  /// l'intera listing con un NoSuchElementError.
  List<WebDavItem> _parseMultiStatus(String xml, String requestPath) {
    final document = XmlDocument.parse(xml);
    final responses = document.findAllElements('d:response');
    final items = <WebDavItem>[];

    for (final response in responses) {
      try {
        final hrefEls = response.findElements('d:href');
        if (hrefEls.isEmpty) continue;
        final href = hrefEls.first.innerText;
        final decodedHref = Uri.decodeFull(href);

        // Salta l'entry della directory stessa
        final normalizedRequest = requestPath.endsWith('/')
            ? requestPath
            : '$requestPath/';
        if (decodedHref.endsWith(normalizedRequest) ||
            decodedHref == _davUrl + normalizedRequest) {
          continue;
        }

        // Preferisci il propstat con status 200 (alcuni server restituiscono
        // più propstat: uno con i successi, uno con le prop not-found).
        final propstats = response.findElements('d:propstat').toList();
        if (propstats.isEmpty) continue;
        XmlElement? propstat;
        for (final ps in propstats) {
          final statusEls = ps.findElements('d:status');
          if (statusEls.isEmpty) continue;
          if (statusEls.first.innerText.contains('200')) {
            propstat = ps;
            break;
          }
        }
        propstat ??= propstats.first;

        final propEls = propstat.findElements('d:prop');
        if (propEls.isEmpty) continue;
        final prop = propEls.first;

        final rtEls = prop.findElements('d:resourcetype');
        final isDir = rtEls.isNotEmpty &&
            rtEls.first.findElements('d:collection').isNotEmpty;

        final segments =
            decodedHref.split('/').where((s) => s.isNotEmpty).toList();
        if (segments.isEmpty) continue;
        final name = Uri.decodeFull(segments.last);

        String? etag;
        final etagEl = prop.findElements('d:getetag');
        if (etagEl.isNotEmpty) {
          etag = etagEl.first.innerText.replaceAll('"', '');
        }

        int? contentLength;
        final clEl = prop.findElements('d:getcontentlength');
        if (clEl.isNotEmpty && clEl.first.innerText.isNotEmpty) {
          contentLength = int.tryParse(clEl.first.innerText);
        }

        DateTime? lastModified;
        final lmEl = prop.findElements('d:getlastmodified');
        if (lmEl.isNotEmpty && lmEl.first.innerText.isNotEmpty) {
          lastModified = _parseHttpDate(lmEl.first.innerText);
        }

        String? contentType;
        final ctEl = prop.findElements('d:getcontenttype');
        if (ctEl.isNotEmpty) {
          contentType = ctEl.first.innerText;
        }

        items.add(WebDavItem(
          path: decodedHref,
          name: name,
          isDirectory: isDir,
          contentLength: contentLength,
          etag: etag,
          lastModified: lastModified,
          contentType: contentType,
        ));
      } catch (e) {
        // Singola entry malformata non deve invalidare tutta la listing.
        // ignore: avoid_print
        print('[WebDAV] Skipping malformed PROPFIND entry: $e');
      }
    }

    return items;
  }

  /// Chiude il client HTTP.
  void dispose() {
    _client.close();
  }
}

/// Eccezione specifica per errori WebDAV.
class WebDavException implements Exception {
  final String message;
  final int statusCode;

  WebDavException(this.message, this.statusCode);

  @override
  String toString() => 'WebDavException($statusCode): $message';
}

/// Thrown when a PUT appears to succeed (201/204) but a follow-up
/// PROPFIND shows the server stored a body whose size does not match
/// what we sent. Indicates a silent truncation somewhere in the HTTP
/// chain (proxy buffer, NSURLSession suspension, Tailscale stall) that
/// the PUT response did not surface as an error. Callers should treat
/// the remote file as poisoned and either retry or escalate.
class WebDavSizeMismatchException implements Exception {
  final String remotePath;
  final int sentBytes;
  final int storedBytes;

  WebDavSizeMismatchException(this.remotePath, this.sentBytes, this.storedBytes);

  @override
  String toString() =>
      'WebDavSizeMismatchException($remotePath): sent ${sentBytes}B but '
      'server stored ${storedBytes}B';
}

/// Thrown when a GET returns 200 with a Content-Length header that
/// disagrees with the number of body bytes actually received. Indicates
/// a silent mid-stream cut by some hop in the chain (proxy, Tailscale
/// relay, NSURLSession suspension) that `package:http` does not flag.
/// Treat the bytes as garbage — never feed them to a JSON/image/zip
/// decoder.
class WebDavTruncatedDownloadException implements Exception {
  final String remotePath;
  final int declaredBytes;
  final int receivedBytes;

  WebDavTruncatedDownloadException(
      this.remotePath, this.declaredBytes, this.receivedBytes);

  @override
  String toString() =>
      'WebDavTruncatedDownloadException($remotePath): server declared '
      '${declaredBytes}B but only ${receivedBytes}B were received';
}

/// Parsa date HTTP (RFC 1123: "Sun, 06 Nov 1994 08:49:37 GMT").
DateTime _parseHttpDate(String dateStr) {
  const months = {
    'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
    'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
  };
  try {
    // Prova ISO 8601 prima
    return DateTime.parse(dateStr);
  } catch (_) {
    // Prova RFC 1123
    final parts = dateStr.split(' ');
    if (parts.length >= 5) {
      final day = int.tryParse(parts[1]) ?? 1;
      final month = months[parts[2]] ?? 1;
      final year = int.tryParse(parts[3]) ?? 2026;
      final timeParts = parts[4].split(':');
      return DateTime.utc(
        year, month, day,
        int.tryParse(timeParts[0]) ?? 0,
        int.tryParse(timeParts[1]) ?? 0,
        timeParts.length > 2 ? (int.tryParse(timeParts[2]) ?? 0) : 0,
      );
    }
    return DateTime.now();
  }
}
