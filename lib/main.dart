import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/core/providers/app_settings_provider.dart';
import 'package:handwriter/core/providers/auth_provider.dart';
import 'package:handwriter/core/providers/offline_providers.dart';
import 'package:handwriter/core/services/crash_logger.dart';
import 'package:handwriter/core/services/file_service.dart';
import 'package:handwriter/core/services/thumbnail_service.dart';
import 'package:handwriter/features/auth/login_screen.dart';
import 'package:handwriter/ui/screens/library_screen.dart';
import 'package:handwriter/ui/theme/hw_theme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() async {
  await runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await CrashLogger.init();

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    final fileService = FileService();
    await fileService.init();

    final thumbnailService = ThumbnailService();
    await thumbnailService.init();

    runApp(ProviderScope(
      overrides: [
        fileServiceProvider.overrideWithValue(fileService),
        thumbnailServiceProvider.overrideWithValue(thumbnailService),
      ],
      child: const HandWriterApp(),
    ));
  }, (error, stack) {
    CrashLogger.append('ZoneError: $error\n$stack');
  });
}

/// Root app — selects palette/variant based on user setting and wraps the
/// tree in [HwThemeScope] so the new UI can read tokens via `HwThemeScope.of`.
class HandWriterApp extends ConsumerWidget {
  const HandWriterApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(appSettingsProvider).themeMode;
    final variant = _variantFor(themeMode, MediaQuery.platformBrightnessOf(context));
    final palette = switch (variant) {
      HwThemeVariant.paper => HwPalette.paper,
      HwThemeVariant.light => HwPalette.light,
      HwThemeVariant.dark => HwPalette.dark,
    };
    return MaterialApp(
      title: 'HandWriter',
      debugShowCheckedModeBanner: false,
      theme: buildHwThemeData(variant),
      home: HwThemeScope(
        palette: palette,
        variant: variant,
        child: const _AuthGate(),
      ),
      builder: (context, child) {
        // Re-inject the scope inside Navigator routes so dialogs & pushed
        // pages can also read the palette.
        return HwThemeScope(
          palette: palette,
          variant: variant,
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }

  HwThemeVariant _variantFor(ThemeMode mode, Brightness platform) {
    switch (mode) {
      case ThemeMode.light:
        return HwThemeVariant.light;
      case ThemeMode.dark:
        return HwThemeVariant.dark;
      case ThemeMode.system:
        // System default → "paper" feel for light, "dark" for dark.
        return platform == Brightness.dark
            ? HwThemeVariant.dark
            : HwThemeVariant.paper;
    }
  }
}

class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final creds = ref.watch(credentialsProvider);
    if (creds == null) return const LoginScreen();
    return const LibraryScreenV2();
  }
}
