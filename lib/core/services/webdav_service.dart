import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
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
  final String serverUrl;
  final String username;
  final String password;
  final String basePath;

  late final String _davUrl;
  late final Map<String, String> _authHeaders;
  final http.Client _client = http.Client();

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
    };
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

    if (streamedResponse.statusCode != 207) {
      throw WebDavException(
        'PROPFIND failed: ${streamedResponse.statusCode}',
        streamedResponse.statusCode,
      );
    }

    final body = await streamedResponse.stream.bytesToString();
    return _parseMultiStatus(body, remotePath);
  }

  /// Scarica un file dal server.
  Future<Uint8List> downloadFile(String remotePath) async {
    final response = await _client.get(
      Uri.parse(_fullUrl(remotePath)),
      headers: _authHeaders,
    ).timeout(const Duration(seconds: AppConfig.webdavTimeoutSeconds));

    if (response.statusCode != 200) {
      throw WebDavException(
        'GET failed: ${response.statusCode}',
        response.statusCode,
      );
    }

    return response.bodyBytes;
  }

  /// Carica un file sul server. Crea o sovrascrive.
  /// Ritorna l'ETag della nuova versione.
  /// [timeoutSeconds] overrides the default timeout for this call.
  Future<String?> uploadFile(String remotePath, Uint8List data,
      {int? timeoutSeconds}) async {
    final response = await _client.put(
      Uri.parse(_fullUrl(remotePath)),
      headers: {
        ..._authHeaders,
        'Content-Type': 'application/octet-stream',
      },
      body: data,
    ).timeout(Duration(seconds: timeoutSeconds ?? AppConfig.webdavTimeoutSeconds));

    if (response.statusCode != 201 && response.statusCode != 204) {
      throw WebDavException(
        'PUT failed: ${response.statusCode}',
        response.statusCode,
      );
    }

    return response.headers['etag'];
  }

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

  /// Ottieni l'ETag di un file remoto (per conflict detection).
  Future<String?> getEtag(String remotePath) async {
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

    if (streamedResponse.statusCode != 207) return null;

    final body = await streamedResponse.stream.bytesToString();
    final document = XmlDocument.parse(body);
    final etagElements = document.findAllElements('d:getetag');
    if (etagElements.isEmpty) return null;
    return etagElements.first.innerText.replaceAll('"', '');
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
  Future<String?> getEtagFast(String remotePath) async {
    try {
      final response = await _client.head(
        Uri.parse(_fullUrl(remotePath)),
        headers: _authHeaders,
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) return null;
      final etag = response.headers['etag'];
      return etag?.replaceAll('"', '');
    } catch (_) {
      return null;
    }
  }

  /// Parsa la risposta XML Multi-Status di PROPFIND.
  List<WebDavItem> _parseMultiStatus(String xml, String requestPath) {
    final document = XmlDocument.parse(xml);
    final responses = document.findAllElements('d:response');
    final items = <WebDavItem>[];

    for (final response in responses) {
      final href = response.findElements('d:href').first.innerText;
      final decodedHref = Uri.decodeFull(href);

      // Salta l'entry della directory stessa
      final normalizedRequest = requestPath.endsWith('/')
          ? requestPath
          : '$requestPath/';
      if (decodedHref.endsWith(normalizedRequest) ||
          decodedHref == _davUrl + normalizedRequest) {
        continue;
      }

      final propstat = response.findElements('d:propstat').first;
      final prop = propstat.findElements('d:prop').first;

      final resourceType = prop.findElements('d:resourcetype').first;
      final isDir = resourceType.findElements('d:collection').isNotEmpty;

      final name = Uri.decodeFull(
        decodedHref.split('/').where((s) => s.isNotEmpty).last,
      );

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
