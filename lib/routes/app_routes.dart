import 'package:flutter/material.dart';
import '../pages/splash/splash_page.dart';
import '../pages/main/main_page.dart';
import '../pages/bookshelf/bookshelf_page.dart';
import '../pages/discovery/discovery_page.dart';
import '../pages/miniprogram/miniprogram_page.dart';
import '../pages/profile/profile_page.dart';
import '../pages/search/search_page.dart';
import '../pages/detail/detail_page.dart';
import '../pages/reader/novel_reader_page.dart';
import '../pages/reader/comic_reader_page.dart';
import '../pages/player/video_player_page.dart';
import '../pages/player/audio_player_page.dart';
import '../pages/explore/explore_show_page.dart';

class AppRoutes {
  static const String splash = '/';
  static const String main = '/main';
  static const String bookshelf = '/bookshelf';
  static const String discovery = '/discovery';
  static const String miniprogram = '/miniprogram';
  static const String profile = '/profile';
  static const String search = '/search';
  static const String detail = '/detail';
  static const String novelReader = '/novel-reader';
  static const String comicReader = '/comic-reader';
  static const String videoPlayer = '/video-player';
  static const String audioPlayer = '/audio-player';
  static const String exploreShow = '/explore-show';

  static Route<dynamic> generateRoute(RouteSettings settings) {
    switch (settings.name) {
      case splash:
        return MaterialPageRoute(builder: (_) => const SplashPage());
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
      case search:
        return MaterialPageRoute(builder: (_) => const SearchPage());
      case detail:
        final args = settings.arguments as Map<String, dynamic>?;
        return MaterialPageRoute(
          builder: (_) => DetailPage(bookUrl: args?['bookUrl'] ?? args?['bookId'] ?? ''),
        );
      case novelReader:
        final args = settings.arguments as Map<String, dynamic>?;
        return MaterialPageRoute(
          builder: (_) => NovelReaderPage(
            bookUrl: args?['bookUrl'] ?? args?['bookId'] ?? '',
            chapterIndex: args?['chapterIndex'] ?? 0,
          ),
        );
      case comicReader:
        final args = settings.arguments as Map<String, dynamic>?;
        return MaterialPageRoute(
          builder: (_) => ComicReaderPage(
            bookId: args?['bookId'] ?? '',
            chapterId: args?['chapterId'] ?? '',
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
