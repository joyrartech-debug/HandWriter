import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/core/providers/canvas_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Library sort strategies.
enum LibrarySortMode {
  modifiedDesc, // last-edited first (default)
  modifiedAsc,
  titleAsc,
  titleDesc,
  createdDesc,
  createdAsc,
  colorGroup, // group by cover color
}

extension LibrarySortModeLabel on LibrarySortMode {
  String get label {
    switch (this) {
      case LibrarySortMode.modifiedDesc: return 'Modificati (più recenti)';
      case LibrarySortMode.modifiedAsc: return 'Modificati (meno recenti)';
      case LibrarySortMode.titleAsc: return 'Titolo A→Z';
      case LibrarySortMode.titleDesc: return 'Titolo Z→A';
      case LibrarySortMode.createdDesc: return 'Creati (più recenti)';
      case LibrarySortMode.createdAsc: return 'Creati (meno recenti)';
      case LibrarySortMode.colorGroup: return 'Colore copertina';
    }
  }

  IconData get icon {
    switch (this) {
      case LibrarySortMode.modifiedDesc:
      case LibrarySortMode.modifiedAsc:
        return Icons.edit_calendar_outlined;
      case LibrarySortMode.titleAsc:
      case LibrarySortMode.titleDesc:
        return Icons.sort_by_alpha_rounded;
      case LibrarySortMode.createdDesc:
      case LibrarySortMode.createdAsc:
        return Icons.calendar_today_outlined;
      case LibrarySortMode.colorGroup:
        return Icons.palette_outlined;
    }
  }
}

/// Combined settings blob so we only touch SharedPreferences once per write.
class AppSettings {
  final Set<String> favoriteNotebookIds;
  final Map<String, DateTime> lastOpenedAt;
  final LibrarySortMode sortMode;
  final bool favoritesFirst;
  final ThemeMode themeMode;
  /// OneNote-style preset rail. Fixed-length 3; a `null` entry means
  /// the slot is empty and the popup shows a "+" placeholder.
  final List<PenPreset?> penPresets;

  const AppSettings({
    this.favoriteNotebookIds = const {},
    this.lastOpenedAt = const {},
    this.sortMode = LibrarySortMode.modifiedDesc,
    this.favoritesFirst = true,
    this.themeMode = ThemeMode.system,
    this.penPresets = const [null, null, null],
  });

  AppSettings copyWith({
    Set<String>? favoriteNotebookIds,
    Map<String, DateTime>? lastOpenedAt,
    LibrarySortMode? sortMode,
    bool? favoritesFirst,
    ThemeMode? themeMode,
    List<PenPreset?>? penPresets,
  }) =>
      AppSettings(
        favoriteNotebookIds: favoriteNotebookIds ?? this.favoriteNotebookIds,
        lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
        sortMode: sortMode ?? this.sortMode,
        favoritesFirst: favoritesFirst ?? this.favoritesFirst,
        themeMode: themeMode ?? this.themeMode,
        penPresets: penPresets ?? this.penPresets,
      );
}

class AppSettingsNotifier extends StateNotifier<AppSettings> {
  static const _prefsKey = 'app_settings_v1';

  AppSettingsNotifier() : super(const AppSettings()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;

      final favIds = (map['fav'] as List?)?.cast<String>().toSet() ?? <String>{};
      final openedRaw = (map['opened'] as Map?)?.cast<String, dynamic>() ?? {};
      final opened = <String, DateTime>{};
      openedRaw.forEach((k, v) {
        final dt = DateTime.tryParse(v as String? ?? '');
        if (dt != null) opened[k] = dt;
      });
      final sort = LibrarySortMode.values.firstWhere(
        (m) => m.name == (map['sort'] as String?),
        orElse: () => LibrarySortMode.modifiedDesc,
      );
      final favFirst = map['fav_first'] as bool? ?? true;
      final theme = ThemeMode.values.firstWhere(
        (m) => m.name == (map['theme'] as String?),
        orElse: () => ThemeMode.system,
      );

      final presetsRaw = (map['pen_presets'] as List?) ?? const [];
      final presets = List<PenPreset?>.generate(3, (i) {
        if (i >= presetsRaw.length) return null;
        final entry = presetsRaw[i];
        if (entry == null) return null;
        return PenPreset.fromJson(
            (entry as Map).cast<String, dynamic>());
      }, growable: false);

      state = AppSettings(
        favoriteNotebookIds: favIds,
        lastOpenedAt: opened,
        sortMode: sort,
        favoritesFirst: favFirst,
        themeMode: theme,
        penPresets: presets,
      );
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode({
        'fav': state.favoriteNotebookIds.toList(),
        'opened': state.lastOpenedAt
            .map((k, v) => MapEntry(k, v.toIso8601String())),
        'sort': state.sortMode.name,
        'fav_first': state.favoritesFirst,
        'theme': state.themeMode.name,
        'pen_presets':
            state.penPresets.map((p) => p?.toJson()).toList(growable: false),
      }));
    } catch (_) {}
  }

  /// Save the current pen-class tool settings into [slot] (0..2). Used
  /// by the popup's preset rail when the user long-presses an empty
  /// slot or chooses "salva qui" from a filled slot.
  void savePenPreset(int slot, PenPreset preset) {
    if (slot < 0 || slot > 2) return;
    final next = List<PenPreset?>.from(state.penPresets);
    while (next.length < 3) {
      next.add(null);
    }
    next[slot] = preset;
    state = state.copyWith(penPresets: next);
    _persist();
  }

  void clearPenPreset(int slot) {
    if (slot < 0 || slot > 2) return;
    final next = List<PenPreset?>.from(state.penPresets);
    while (next.length < 3) {
      next.add(null);
    }
    next[slot] = null;
    state = state.copyWith(penPresets: next);
    _persist();
  }

  void toggleFavorite(String notebookId) {
    final next = Set<String>.from(state.favoriteNotebookIds);
    if (next.contains(notebookId)) {
      next.remove(notebookId);
    } else {
      next.add(notebookId);
    }
    state = state.copyWith(favoriteNotebookIds: next);
    _persist();
  }

  void markOpened(String notebookId) {
    final next = Map<String, DateTime>.from(state.lastOpenedAt);
    next[notebookId] = DateTime.now();
    state = state.copyWith(lastOpenedAt: next);
    _persist();
  }

  void setSortMode(LibrarySortMode mode) {
    state = state.copyWith(sortMode: mode);
    _persist();
  }

  void setFavoritesFirst(bool v) {
    state = state.copyWith(favoritesFirst: v);
    _persist();
  }

  void setThemeMode(ThemeMode mode) {
    state = state.copyWith(themeMode: mode);
    _persist();
  }

  /// Clean up entries for deleted notebooks.
  void purgeNotebook(String notebookId) {
    final favs = Set<String>.from(state.favoriteNotebookIds)..remove(notebookId);
    final opened = Map<String, DateTime>.from(state.lastOpenedAt)..remove(notebookId);
    state = state.copyWith(
      favoriteNotebookIds: favs,
      lastOpenedAt: opened,
    );
    _persist();
  }
}

final appSettingsProvider =
    StateNotifierProvider<AppSettingsNotifier, AppSettings>((ref) {
  return AppSettingsNotifier();
});
