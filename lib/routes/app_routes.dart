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
import '../pages/profile/read_record_page.dart';
import '../pages/search/search_page.dart';
import '../pages/detail/detail_page.dart';
import '../pages/reader/novel_reader_page.dart';
import '../pages/reader/comic_reader_page.dart';
import '../pages/player/video_player_page.dart';
import '../pages/player/audio_player_page.dart';
import '../pages/explore/explore_show_page.dart';
import '../pages/debug/book_source_debug_page.dart';
import '../pages/detail/chapter_list_page.dart';

class AppRoutes {
  static const String main = '/';
  static const String bookshelf = '/bookshelf';
  static const String discovery = '/discovery';
  static const String miniprogram = '/miniprogram';
  static const String profile = '/profile';
  static const String bookSourceManage = '/book-source-manage';
  static const String bookSourceEdit = '/book-source-edit';
  static const String readRecord = '/read-record';
  static const String search = '/search';
  static const String detail = '/detail';
  static const String novelReader = '/novel-reader';
  static const String comicReader = '/comic-reader';
  static const String videoPlayer = '/video-player';
  static const String audioPlayer = '/audio-player';
  static const String exploreShow = '/explore-show';
  static const String bookSourceDebug = '/book-source-debug';
  static const String chapterList = '/chapter-list';

  static Route<dynamic> generateRoute(RouteSettings settings) {
    switch (settings.name) {
      case main:
        return MaterialPageRoute(builder: (_) => const MainPage());
      case bookshelf:
        return MaterialPageRoute(builder: (_) => const BookshelfPage());
      case discovery:
        return MaterialPageRoute(builder: (_) => const DiscoveryPage());
      case miniprogram:
        return MaterialPageRoute(builder: (_) => const MiniprogramPage());
      case profile:
        return MaterialPageRoute(builder: (_) => const ProfilePage());
      case bookSourceManage:
        return MaterialPageRoute(builder: (_) => const BookSourceManagePage());
      case bookSourceEdit:
        final args = settings.arguments as Map<String, dynamic>?;
        return MaterialPageRoute(
          builder: (_) => BookSourceEditPage(sourceUrl: args?['sourceUrl']),
        );
      case readRecord:
        final args = settings.arguments as Map<String, dynamic>?;
        return MaterialPageRoute(
          builder: (_) => ReadRecordPage(bookUrl: args?['bookUrl']),
        );
      case search:
        return MaterialPageRoute(builder: (_) => const SearchPage());
      case detail:
        final args = settings.arguments as Map<String, dynamic>?;
        final bookData = args?['bookData'];
        return MaterialPageRoute(
          builder: (_) => DetailPage(
            bookUrl: args?['bookUrl'] ?? args?['bookId'] ?? '',
            initialBook: bookData is Book
                ? bookData
                : bookData is Map
                    ? Book.fromJson(Map<String, dynamic>.from(bookData))
                    : null,
          ),
        );
      case novelReader:
        final args = settings.arguments as Map<String, dynamic>?;
        final bookData = args?['bookData'];
        return MaterialPageRoute(
          builder: (_) => NovelReaderPage(
            bookUrl: args?['bookUrl'] ?? args?['bookId'] ?? '',
            chapterIndex: args?['chapterIndex'] ?? 0,
            initialBook: bookData is Book
                ? bookData
                : bookData is Map
                    ? Book.fromJson(Map<String, dynamic>.from(bookData))
                    : null,
          ),
        );
      case comicReader:
        final args = settings.arguments as Map<String, dynamic>?;
        final initialBook = args?['initialBook'];
        return MaterialPageRoute(
          builder: (_) => ComicReaderPage(
            bookUrl: args?['bookUrl'] ?? '',
            chapterIndex: args?['chapterIndex'] ?? 0,
            initialBook: initialBook is Book ? initialBook : null,
          ),
        );
      case videoPlayer:
        final args = settings.arguments as Map<String, dynamic>?;
        return MaterialPageRoute(
          builder: (_) => VideoPlayerPage(
            bookId: args?['bookId'] ?? '',
            episodeId: args?['episodeId'] ?? '',
          ),
        );
      case audioPlayer:
        final args = settings.arguments as Map<String, dynamic>?;
        return MaterialPageRoute(
          builder: (_) => AudioPlayerPage(
            bookId: args?['bookId'] ?? '',
            trackId: args?['trackId'] ?? '',
          ),
        );
      case exploreShow:
        final args = settings.arguments as Map<String, dynamic>?;
        return MaterialPageRoute(
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
        return MaterialPageRoute(
          builder: (_) => BookSourceDebugPage(
            sourceUrl: debugArgs?['sourceUrl'],
            source: sourceObj is BookSource ? sourceObj : null,
          ),
        );
      case chapterList:
        final args = settings.arguments as Map<String, dynamic>?;
        final bookData = args?['bookData'];
        return MaterialPageRoute(
          builder: (_) => ChapterListPage(
            bookUrl: args?['bookUrl'] ?? '',
            currentChapterIndex: args?['currentChapterIndex'] ?? 0,
            initialBook: bookData is Book
                ? bookData
                : bookData is Map
                    ? Book.fromJson(Map<String, dynamic>.from(bookData))
                    : null,
          ),
        );
      default:
        return MaterialPageRoute(
          builder: (_) => Scaffold(
            body: Center(
              child: Text('未找到路由: ${settings.name}'),
            ),
          ),
        );
    }
  }
}
