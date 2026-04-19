import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:handwriter/core/services/webdav_service.dart';

/// Credenziali Nextcloud.
class NextcloudCredentials {
  final String serverUrl;
  final String username;
  final String password;

  const NextcloudCredentials({
    required this.serverUrl,
    required this.username,
    required this.password,
  });

  Map<String, String> toMap() => {
        'serverUrl': serverUrl,
        'username': username,
        'password': password,
      };

  factory NextcloudCredentials.fromMap(Map<String, String> map) =>
      NextcloudCredentials(
        serverUrl: map['serverUrl']!,
        username: map['username']!,
        password: map['password']!,
      );
}

/// Provider per le credenziali salvate.
final credentialsProvider =
    StateNotifierProvider<CredentialsNotifier, NextcloudCredentials?>((ref) {
  return CredentialsNotifier();
});

class CredentialsNotifier extends StateNotifier<NextcloudCredentials?> {
  CredentialsNotifier() : super(null) {
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('nc_server_url');
    final user = prefs.getString('nc_username');
    final pass = prefs.getString('nc_password');
    if (url != null && user != null && pass != null) {
      state = NextcloudCredentials(
        serverUrl: url,
        username: user,
        password: pass,
      );
    }
  }

  Future<void> login(NextcloudCredentials creds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nc_server_url', creds.serverUrl);
    await prefs.setString('nc_username', creds.username);
    await prefs.setString('nc_password', creds.password);
    state = creds;
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('nc_server_url');
    await prefs.remove('nc_username');
    await prefs.remove('nc_password');
    state = null;
  }
}

/// Provider per il servizio WebDAV, dipende dalle credenziali.
///
/// On logout/credentials change the underlying `http.Client` must be closed
/// explicitly, otherwise the socket + connection pool leak for the lifetime
/// of the app (noticeable after repeated login/logout cycles on iPad).
final webdavServiceProvider = Provider<WebDavService?>((ref) {
  final creds = ref.watch(credentialsProvider);
  if (creds == null) return null;
  final service = WebDavService(
    serverUrl: creds.serverUrl,
    username: creds.username,
    password: creds.password,
  );
  ref.onDispose(service.dispose);
  return service;
});
