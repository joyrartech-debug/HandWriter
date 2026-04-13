import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/core/providers/auth_provider.dart';
import 'package:handwriter/core/providers/offline_providers.dart';
import 'package:handwriter/core/services/file_service.dart';
import 'package:handwriter/features/auth/login_screen.dart';
import 'package:handwriter/features/library/library_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final fileService = FileService();
  await fileService.init();

  runApp(ProviderScope(
    overrides: [
      fileServiceProvider.overrideWithValue(fileService),
    ],
    child: const HandWriterApp(),
  ));
}

class HandWriterApp extends StatelessWidget {
  const HandWriterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HandWriter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1565C0),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF1565C0),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const _AuthGate(),
    );
  }
}

/// Smista tra Login e Libreria in base alle credenziali salvate.
class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final creds = ref.watch(credentialsProvider);
    if (creds == null) {
      return const LoginScreen();
    }
    return const LibraryScreen();
  }
}

