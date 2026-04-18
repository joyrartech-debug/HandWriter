import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:handwriter/shared/models/ncnote_format.dart';

/// A set of pages cut from a notebook, ready to be pasted into another.
///
/// Created by [_PageManagerSheetState._cutSelected] when the user cuts pages
/// from the page manager. Consumed by [_PageManagerSheetState._pastePages]
/// when the user pastes into a different (or the same) notebook.
class PageClipboard {
  /// The actual page data (strokes, text, images …).
  final List<PageData> pages;

  /// The document structure entries for the cut pages (preserves chapter id,
  /// file name template, page number — these are renumbered on paste).
  final List<PageEntry> entries;

  /// The id of the notebook from which the pages were cut.
  final String sourceNotebookId;

  const PageClipboard({
    required this.pages,
    required this.entries,
    required this.sourceNotebookId,
  });
}

/// Global page clipboard.
///
/// Non-null when pages have been cut and are waiting to be pasted.
/// Cleared after a successful paste or when the user dismisses it.
final pageClipboardProvider = StateProvider<PageClipboard?>((_) => null);
