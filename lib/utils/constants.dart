class Constants {
  static const String appName = 'mr';
  static const String appSubtitle = '多媒体阅读器';
  static const String nojsVersion = '1.0.0';
  
  static const String defaultCacheDir = 'mr_cache';
  static const int defaultConcurrentSearch = 5;
  static const int defaultCacheExpireDays = 7;
  
  static const List<String> supportedBookFormats = [
    '.txt',
    '.epub',
    '.pdf',
  ];
  
  static const List<String> supportedComicFormats = [
    '.zip',
    '.cbz',
    '.cbr',
    '.rar',
  ];
  
  static const List<String> supportedMediaFormats = [
    '.mp4',
    '.mkv',
    '.avi',
    '.mp3',
    '.m4a',
    '.flac',
  ];
  
  static const Map<String, String> mediaTypeNames = {
    'novel': '小说',
    'comic': '漫画',
    'video': '视频',
    'audio': '音频',
  };
}
