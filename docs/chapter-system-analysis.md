# Chapter & Page Management System - HandWriter App

## Data Models

### Chapter (lib/shared/models/ncnote_format.dart)
- **id** (String): Unique identifier for the chapter
- **title** (String): Display name of the chapter
- **pageIds** (List<String>): List of pageIds associated with this chapter
- Stored in NotebookMetadata.chapters list

### PageEntry (lib/shared/models/ncnote_format.dart)
- **pageId** (String): Unique page identifier
- **pageNumber** (int): Display page number
- **fileName** (String): File path like "page_001.json"
- **width/height** (double): Page dimensions
- **thumbnailFile** (String?): Optional thumbnail
- **chapterId** (String?): **KEY FIELD** - links page to a chapter
- **lastModified** (DateTime?): Last modification timestamp
- Stored in DocumentStructure.pages list

### NotebookMetadata (lib/shared/models/ncnote_format.dart)
- Contains List<Chapter> chapters

### DocumentStructure (lib/shared/models/ncnote_format.dart)
- Contains List<PageEntry> pages (with chapterId field on each)

### CanvasState (lib/core/providers/canvas_provider.dart)
- **activeChapterId** (String?): Currently active chapter filter (null = show all)
- filteredPageIndices: Computed list of visible page indices based on activeChapterId

## Key Filtering Logic

### filteredPageIndices (CanvasState getter)
```dart
List<int> get filteredPageIndices {
  if (activeChapterId == null) {
    return List.generate(document.pages.length, (i) => i);  // All pages
  }
  return [
    for (int i = 0; i < document.pages.length; i++)
      if (document.pages[i].chapterId == activeChapterId) i,
  ];
}
```

## Chapter Management Methods

All in CanvasNotifier (lib/core/providers/canvas_provider.dart):

### setActiveChapter(String? chapterId)
- Sets activeChapterId filter
- If null: clears filter (shows all pages)
- If provided: jumps to first page of that chapter

### addChapter(String title)
- Creates new Chapter with UUID
- Assigns CURRENT page to the new chapter
- Sets activeChapterId to the new chapter

### renameChapter(String chapterId, String title)
- Updates chapter title in metadata.chapters

### reorderChapters(int oldIndex, int newIndex)
- Reorders chapters list in metadata

### deleteChapter(String chapterId)
- Removes chapter from metadata.chapters
- Clears chapterId from ALL pages that had this chapter
- Pages REMAIN but become unassigned

### assignPageToChapter(int pageIndex, String? chapterId)
- Updates PageEntry.chapterId at given index

## Page Creation & Chapter Assignment

### addPage()
- Creates new page after current position
- **AUTO-ASSIGNS TO ACTIVE CHAPTER**: chapterId: s.activeChapterId

### insertPageAt(int index)
- **INHERITS chapter from adjacent page**

### duplicatePage(int index)
- **BUG/LIMITATION**: Does NOT preserve chapterId!

## Page Navigation with Filtering

### nextPage() / prevPage()
- Uses filteredPageIndices to navigate
- Respects chapter filter

## UI Integration (canvas_screen.dart)

### Chapter Tabs (_buildPageNav)
- Displays chapter list as horizontal ChoiceChip tabs
- Supports drag-to-reorder chapters

### Chapter Picker (_showChapterPicker)
- Modal showing available chapters
- "Nessuno" option to clear chapter
