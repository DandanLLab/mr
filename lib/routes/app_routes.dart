import 'package:flutter/material.dart';
import '../models/book.dart';
import '../models/book_source.dart';
import '../pages/main/main_page.dart';
import '../pages/bookshelf/bookshelf_page.dart';
import '../pages/discovery/discovery_page.dart';
import '../pages/miniprogram/miniprogram_page.dart';
import '../pages/profile/profile_page.dart';
import '../pages/profile/book_source_manage_page.dart';
import '../pages/profile/book_source_edit_page.dart';
import '../pages/profile/book_source_import_page.dart';
import '../pages/profile/read_record_page.dart';
import '../pages/profile/bookmark_page.dart';
import '../pages/profile/storage_manage_page.dart';
import '../pages/profile/backup_restore_page.dart';
import '../pages/profile/replace_rule_page.dart';
import '../pages/profile/dict_rule_page.dart';
import '../pages/profile/txt_toc_rule_page.dart';
import '../pages/search/search_page.dart';
import '../pages/detail/detail_page.dart';
import '../pages/reader/novel_reader_page.dart';
import '../pages/reader/comic_reader_page.dart';
import '../pages/player/video_player_page.dart';
import '../pages/player/audio_player_page.dart';
import '../pages/explore/explore_show_page.dart';
import '../pages/debug/book_source_debug_page.dart';
import '../pages/debug/crash_log_panel.dart';
import '../pages/detail/chapter_list_page.dart';
import '../pages/web/internal_browser_page.dart';

class AppPageRoute<T> extends PageRouteBuilder<T> {
  AppPageRoute({
    required WidgetBuilder builder,
    RouteSettings? settings,
    bool maintainState = true,
    bool fullscreenDialog = false,
  }) : super(
          settings: settings,
          maintainState: maintainState,
          fullscreenDialog: fullscreenDialog,
          allowSnapshotting: false,
          transitionDuration: const Duration(milliseconds: 250),
          reverseTransitionDuration: const Duration(milliseconds: 250),
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curve = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return FadeTransition(
              opacity: curve,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0.0, 0.08),
                  end: Offset.zero,
                ).animate(curve),
                child: child,
              ),
            );
          },
        );
}

class AppRoutes {
  static const String main = '/';
  static const String bookshelf = '/bookshelf';
  static const String discovery = '/discovery';
  static const String miniprogram = '/miniprogram';
  static const String profile = '/profile';
  static const String bookSourceManage = '/book-source-manage';
  static const String bookSourceEdit = '/book-source-edit';
  static const String bookSourceImport = '/book-source-import';
  static const String readRecord = '/read-record';
  static const String bookmark = '/bookmark';
  static const String storageManage = '/storage-manage';
  static const String backupRestore = '/backup-restore';
  static const String replaceRule = '/replace-rule';
  static const String dictRule = '/dict-rule';
  static const String txtTocRule = '/txt-toc-rule';
  static const String search = '/search';
  static const String detail = '/detail';
  static const String novelReader = '/novel-reader';
  static const String comicReader = '/comic-reader';
  static const String videoPlayer = '/video-player';
  static const String audioPlayer = '/audio-player';
  static const String exploreShow = '/explore-show';
  static const String bookSourceDebug = '/book-source-debug';
  static const String crashLogs = '/crash-logs';
  static const String chapterList = '/chapter-list';
  static const String internalBrowser = '/internal-browser';

  static Route<dynamic> generateRoute(RouteSettings settings) {
    switch (settings.name) {
      case main:
        return AppPageRoute(builder: (_) => const MainPage());
      case bookshelf:
        return AppPageRoute(builder: (_) => const BookshelfPage());
      case discovery:
        return AppPageRoute(builder: (_) => const DiscoveryPage());
      case miniprogram:
        return AppPageRoute(builder: (_) => const MiniprogramPage());
      case profile:
        return AppPageRoute(builder: (_) => const ProfilePage());
      case bookSourceManage:
        return AppPageRoute(builder: (_) => const BookSourceManagePage());
      case bookSourceEdit:
        final args = settings.arguments as Map<String, dynamic>?;
        return AppPageRoute(
          builder: (_) => BookSourceEditPage(sourceUrl: args?['sourceUrl']),
        );
      case readRecord:
        final args = settings.arguments as Map<String, dynamic>?;
        return AppPageRoute(
          builder: (_) => ReadRecordPage(bookUrl: args?['bookUrl']),
        );
      case bookmark:
        return AppPageRoute(builder: (_) => const BookmarkPage());
      case storageManage:
        return AppPageRoute(builder: (_) => const StorageManagePage());
      case backupRestore:
        return AppPageRoute(builder: (_) => const BackupRestorePage());
      case replaceRule:
        return AppPageRoute(builder: (_) => const ReplaceRulePage());
      case dictRule:
        return AppPageRoute(builder: (_) => const DictRulePage());
      case txtTocRule:
        return AppPageRoute(builder: (_) => const TxtTocRulePage());
      case search:
        final args = settings.arguments as Map<String, dynamic>?;
        return AppPageRoute(
          builder: (_) => SearchPage(
            initialKeyword: args?['keyword'],
            sourceUrl: args?['sourceUrl'],
          ),
        );
      case detail:
        final args = settings.arguments;
        Map<String, dynamic>? argsMap;
        if (args is Map<String, dynamic>) {
          argsMap = args;
        } else if (args is Map) {
          argsMap = Map<String, dynamic>.from(args);
        }
        final bookData = argsMap?['bookData'];
        Book? initialBook;
        if (bookData is Book) {
          initialBook = bookData;
        } else if (bookData is Map) {
          try {
            initialBook = Book.fromJson(Map<String, dynamic>.from(bookData));
          } catch (e) {
            debugPrint('Book.fromJson error: $e');
          }
        }
        return AppPageRoute(
          builder: (_) => DetailPage(
            bookUrl: argsMap?['bookUrl'] ?? argsMap?['bookId'] ?? '',
            initialBook: initialBook,
          ),
        );
      case novelReader:
        final args = settings.arguments;
        Map<String, dynamic>? argsMap;
        if (args is Map<String, dynamic>) {
          argsMap = args;
        } else if (args is Map) {
          argsMap = Map<String, dynamic>.from(args);
        }
        final bookData = argsMap?['bookData'];
        Book? initialBook;
        if (bookData is Book) {
          initialBook = bookData;
        } else if (bookData is Map) {
          try {
            initialBook = Book.fromJson(Map<String, dynamic>.from(bookData));
          } catch (e) {
            debugPrint('Book.fromJson error: $e');
          }
        }
        return AppPageRoute(
          builder: (_) => NovelReaderPage(
            bookUrl: argsMap?['bookUrl'] ?? argsMap?['bookId'] ?? '',
            chapterIndex: argsMap?['chapterIndex'] ?? 0,
            resumeProgress:
                argsMap?['resumeProgress'] == true ||
                !(argsMap?.containsKey('chapterIndex') ?? false),
            initialBook: initialBook,
          ),
        );
      case comicReader:
        final args = settings.arguments;
        Map<String, dynamic>? argsMap;
        if (args is Map<String, dynamic>) {
          argsMap = args;
        } else if (args is Map) {
          argsMap = Map<String, dynamic>.from(args);
        }
        final bookData = argsMap?['bookData'];
        Book? initialBook;
        if (bookData is Book) {
          initialBook = bookData;
        } else if (bookData is Map) {
          try {
            initialBook = Book.fromJson(Map<String, dynamic>.from(bookData));
          } catch (e) {
            debugPrint('Book.fromJson error: $e');
          }
        }
        return AppPageRoute(
          builder: (_) => ComicReaderPage(
            bookUrl: argsMap?['bookUrl'] ?? argsMap?['bookId'] ?? '',
            chapterIndex: argsMap?['chapterIndex'] ?? 0,
            resumeProgress:
                argsMap?['resumeProgress'] == true ||
                !(argsMap?.containsKey('chapterIndex') ?? false),
            initialBook: initialBook,
          ),
        );
      case videoPlayer:
        final args = settings.arguments as Map<String, dynamic>?;
        return AppPageRoute(
          builder: (_) => VideoPlayerPage(
            bookId: args?['bookId'] ?? '',
            episodeId: args?['episodeId'] ?? '',
          ),
        );
      case audioPlayer:
        final args = settings.arguments as Map<String, dynamic>?;
        return AppPageRoute(
          builder: (_) => AudioPlayerPage(
            bookId: args?['bookId'] ?? '',
            trackId: args?['trackId'] ?? '',
          ),
        );
      case exploreShow:
        final args = settings.arguments as Map<String, dynamic>?;
        return AppPageRoute(
          builder: (_) => ExploreShowPage(
            sourceUrl: args?['sourceUrl'] ?? '',
            sourceName: args?['sourceName'] ?? '',
            exploreName: args?['exploreName'] ?? '',
            exploreUrl: args?['exploreUrl'] ?? '',
          ),
        );
      case bookSourceDebug:
        final debugArgs = settings.arguments as Map<String, dynamic>?;
        final sourceObj = debugArgs?['source'];
        return AppPageRoute(
          builder: (_) => BookSourceDebugPage(
            sourceUrl: debugArgs?['sourceUrl'],
            source: sourceObj is BookSource ? sourceObj : null,
          ),
        );
      case crashLogs:
        return AppPageRoute(builder: (_) => const CrashLogPanel());
      case chapterList:
        final args = settings.arguments;
        Map<String, dynamic>? argsMap;
        if (args is Map<String, dynamic>) {
          argsMap = args;
        } else if (args is Map) {
          argsMap = Map<String, dynamic>.from(args);
        }
        final bookData = argsMap?['bookData'];
        Book? initialBook;
        if (bookData is Book) {
          initialBook = bookData;
        } else if (bookData is Map) {
          try {
            initialBook = Book.fromJson(Map<String, dynamic>.from(bookData));
          } catch (e) {
            debugPrint('Book.fromJson error: $e');
          }
        }
        return AppPageRoute(
          builder: (_) => ChapterListPage(
            bookUrl: argsMap?['bookUrl'] ?? '',
            currentChapterIndex: argsMap?['currentChapterIndex'] ?? 0,
            initialBook: initialBook,
          ),
        );
      case bookSourceImport:
        final args = settings.arguments;
        String? initialText;
        if (args is String) {
          initialText = args;
        } else if (args is Map) {
          initialText = args['text']?.toString();
        }
        return AppPageRoute(
          builder: (_) => BookSourceImportPage(initialText: initialText),
        );
      case internalBrowser:
        final args = settings.arguments as Map<String, dynamic>?;
        final rawHeaders = args?['headers'];
        return AppPageRoute(
          builder: (_) => InternalBrowserPage(
            url: args?['url'] ?? '',
            title: args?['title'] ?? '',
            sourceUrl: args?['sourceUrl'] ?? '',
            sourceName: args?['sourceName'] ?? '',
            headers: rawHeaders is Map
                ? rawHeaders.map(
                    (key, value) => MapEntry(key.toString(), value.toString()),
                  )
                : const {},
          ),
        );
      default:
        return AppPageRoute(
          builder: (_) =>
              Scaffold(body: Center(child: Text('未找到路由: ${settings.name}'))),
        );
    }
  }
}
