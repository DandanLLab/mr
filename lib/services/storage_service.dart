import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

class StorageService {
  static final StorageService instance = StorageService._internal();
  StorageService._internal();

  Box? _settingsBox;
  Box? _bookshelfBox;
  Box? _cacheBox;
  Box? _bookSourceBox;

  bool _initialized = false;
  String? _initError;

  /// 正在恢复中的 Box 名集合，防止 sync 读 catch 多次触发恢复任务
  final Set<String> _recoveringBoxes = {};

  bool get isInitialized => _initialized;
  String? get initError => _initError;

  /// 打开单个 Box，失败时（如 HiveError: unknown typeId 数据损坏）自动删文件重建
  /// 只清这一个 Box，不影响其他 Box 的数据
  ///
  /// 关键修复：Hive 2.x 是懒加载的 —— openBox() 成功不代表数据完整，
  /// 后续 box.get(key) 时才会反序列化对应 value。
  /// 如果某个 value 的二进制数据损坏（如 typeId=101 未注册 adapter），
  /// 会在业务代码中抛 HiveError，逃逸到 zone 触发崩溃弹窗。
  /// 这里在打开后立即做"健康检查"逐 key 试读，把损坏的 key 提前删除，
  /// 保留其他有效数据，避免清空整个 Box。
  Future<Box?> _openBoxWithRecovery(String name) async {
    try {
      Box box;
      if (Hive.isBoxOpen(name)) {
        box = Hive.box(name);
      } else {
        box = await Hive.openBox(name);
      }
      // 健康检查：逐 key 试读，强制反序列化，把懒加载的损坏数据提前暴露
      await _healthCheck(box);
      return box;
    } catch (e) {
      debugPrint('❌ 打开 $name Box失败: $e，尝试重建该 Box...');
      return await _rebuildBox(name);
    }
  }

  /// 重建 Box：close → 等待事件循环 → delete → 等待 → openBox → healthCheck
  ///
  /// 关键修复：Hive 2.x 在 deleteBoxFromDisk 后立即 openBox 会抛
  /// PathNotFoundException —— Hive 内部 isBoxOpen 状态没及时清理，
  /// openBox 复用了已关闭的 Box 引用但磁盘文件已删。
  /// 这里通过 Future.delayed(Duration.zero) 让出事件循环，确保
  /// Hive 内部 registry 完全清理后再 openBox。
  /// 同时如果首次重建仍失败，再重试一次（双重保险）。
  ///
  /// 关键修复 2：deleteBoxFromDisk 失败被 catch 吞掉时，openBox 打开的是
  /// 旧损坏文件（仍含 typeId 非法的 frame）。这里在 openBox 后强制
  /// _healthCheck 逐 key 试读，删除损坏 key，避免损坏数据继续存在。
  Future<Box?> _rebuildBox(String name, {int retry = 0}) async {
    try {
      await _safeCloseBox(name);
      // 让出事件循环，确保 Hive 内部 isBoxOpen 标志位清理
      await Future.delayed(Duration.zero);
      // 二次确认 close：Hive 2.x 偶发 close 未完成的情况
      if (Hive.isBoxOpen(name)) {
        try {
          await Hive.box(name).close();
        } catch (_) {}
        await Future.delayed(Duration.zero);
      }
      try {
        await Hive.deleteBoxFromDisk(name);
      } catch (_) {
        // 文件不存在也无所谓，反正要重建
      }
      await Future.delayed(Duration.zero);
      final box = await Hive.openBox(name);
      // 健康检查：若 delete 失败，openBox 打开的是旧损坏文件，
      // 这里逐 key 试读把损坏数据清理掉（_healthCheck 内部 keys 读取失败会 rethrow）
      await _healthCheck(box);
      debugPrint('✅ $name Box 重建成功（该 Box 数据已清空）');
      return box;
    } catch (e2) {
      debugPrint('❌ 重建 $name Box失败(第 $retry 次): $e2');
      // 首次重建失败时再重试一次（应对 Hive 内部状态未清理的竞态）
      if (retry < 1) {
        await Future.delayed(const Duration(milliseconds: 50));
        return _rebuildBox(name, retry: retry + 1);
      }
      return null;
    }
  }

  /// Box 健康检查：逐 key 试读，遇到 HiveError（如 unknown typeId）时删除该损坏 key。
  ///
  /// 设计原则：**容错优先**，不因单个 key 损坏就让整个 Box 重建。
  /// - keys.toList() 复制一份，避免遍历中 delete 改动原迭代器
  /// - 每个 key 独立 try-catch，单 key 失败不影响其他 key 检查
  /// - 删除损坏 key 失败时**不抛错**，只记录（避免 _openBoxWithRecovery 误以为
  ///   整个 Box 损坏而走重建路径，反而把其他有效数据全清了）
  /// - 只有 keys 本身读不出（Box 文件级损坏）才向上抛触发重建
  Future<void> _healthCheck(Box box) async {
    final List keys;
    try {
      keys = box.keys.toList();
    } catch (e) {
      // 连 keys 都读不出，Box 严重损坏，需要整个重建
      debugPrint('⚠️ Box ${box.name} keys 读取失败，需要重建: $e');
      rethrow;
    }
    var corruptCount = 0;
    var deleteFailCount = 0;
    for (final key in keys) {
      try {
        // 强制反序列化对应 value，触发可能的 HiveError
        box.get(key);
      } catch (e) {
        final errStr = e.toString();
        // 仅处理 Hive 反序列化错误（typeId 非法、adapter 缺失等）
        if (errStr.contains('HiveError') ||
            errStr.contains('unknown typeId') ||
            errStr.contains('Did you forget to register an adapter')) {
          corruptCount++;
          debugPrint('⚠️ Box ${box.name} key=$key 数据损坏，删除该 key: $errStr');
          try {
            await box.delete(key);
          } catch (delErr) {
            // 删除失败不抛错：单 key 删除失败不等于整个 Box 损坏，
            // 抛错会触发 _rebuildBox 清空整个 Box，得不偿失
            deleteFailCount++;
            debugPrint('⚠️ Box ${box.name} 删除损坏 key=$key 失败（跳过，不影响其他 key）: $delErr');
          }
        } else {
          // 非 HiveError（磁盘 IO、权限等）记录但不抛错，避免误重建
          debugPrint('⚠️ Box ${box.name} key=$key 读取异常（非 HiveError，跳过）: $e');
        }
      }
    }
    if (corruptCount > 0) {
      debugPrint('🔧 Box ${box.name} 健康检查完成，'
          '发现 $corruptCount 个损坏 key，'
          '${corruptCount - deleteFailCount} 个已删除，'
          '$deleteFailCount 个删除失败');
    }
  }

  /// 安全关闭 Box
  Future<void> _safeCloseBox(String name) async {
    try {
      if (Hive.isBoxOpen(name)) {
        await Hive.box(name).close();
      }
    } catch (_) {}
  }

  /// 异步恢复损坏的 Box（用于同步读取方法 catch 中调用）
  /// - 带去重保护：若同名 Box 已在恢复中，本次直接返回，避免重复触发
  /// - 恢复完成（无论成功或失败）后清除标记，允许下次失败再触发一次
  /// - 成功时通过 onRecovered 回调写回 _xxBox 字段
  void _recoverBoxAsync(String name, void Function(Box) onRecovered) {
    if (_recoveringBoxes.contains(name)) {
      debugPrint('⚠️ StorageService: Box $name 已在恢复中，跳过重复触发');
      return;
    }
    _recoveringBoxes.add(name);
    _recoverBox(name, onRecovered).whenComplete(() {
      _recoveringBoxes.remove(name);
    }).catchError((e) {
      debugPrint('❌ StorageService: 异步恢复 Box $name 失败: $e');
    });
  }

  /// 恢复损坏的 Box：关闭 → 删文件 → 重新打开 → healthCheck
  ///
  /// 关键修复：与 _rebuildBox 一致，openBox 后调用 _healthCheck，
  /// 应对 deleteBoxFromDisk 失败导致 openBox 打开旧损坏文件的情况。
  Future<void> _recoverBox(String name, void Function(Box) onRecovered) async {
    debugPrint('🔧 StorageService: 恢复损坏的 Box: $name');
    await _safeCloseBox(name);
    try {
      await Hive.deleteBoxFromDisk(name);
    } catch (_) {}
    try {
      final box = await Hive.openBox(name);
      // 健康检查：清理可能残留的损坏 key
      try {
        await _healthCheck(box);
      } catch (e) {
        // keys 读取失败，Box 严重损坏，但不再 retry，直接返回（业务层会再次触发恢复）
        debugPrint('⚠️ StorageService: Box $name 恢复后健康检查失败: $e');
      }
      onRecovered(box);
      debugPrint('✅ StorageService: Box $name 恢复成功');
    } catch (e) {
      debugPrint('❌ StorageService: Box $name 恢复失败: $e');
    }
  }

  /// 初始化：逐个打开 4 个 Box，单个失败只清那一个 Box（不影响其他 Box 数据）
  Future<void> init() async {
    try {
      _settingsBox = await _openBoxWithRecovery('settings');
      _bookshelfBox = await _openBoxWithRecovery('bookshelf');
      _cacheBox = await _openBoxWithRecovery('cache');
      _bookSourceBox = await _openBoxWithRecovery('bookSource');

      // settings 是关键 Box，必须可用；其他 Box 失败可降级运行
      if (_settingsBox != null) {
        _initialized = true;
        _initError = null;
        debugPrint('✅ StorageService 初始化成功 '
            '(settings=${_settingsBox != null}, bookshelf=${_bookshelfBox != null}, '
            'cache=${_cacheBox != null}, bookSource=${_bookSourceBox != null})');
      } else {
        _initialized = false;
        _initError = '关键 Box (settings) 打开失败';
        debugPrint('❌ $_initError');
      }
    } catch (e) {
      _initError = e.toString();
      _initialized = false;
      debugPrint('❌ StorageService 初始化失败: $e');
    }
  }

  /// 确保已初始化，未初始化则尝试初始化
  Future<bool> _ensureInitialized() async {
    if (_initialized && _settingsBox != null) return true;
    debugPrint('⚠️ StorageService: 未初始化，尝试初始化...');
    try {
      await init();
      return _initialized && _settingsBox != null;
    } catch (e) {
      debugPrint('❌ StorageService 初始化失败: $e');
      return false;
    }
  }

  /// 确保指定 Box 可用，不可用则尝试打开 / 重建
  Future<Box?> _ensureBox(String name, Box? currentBox) async {
    if (currentBox != null && currentBox.isOpen) return currentBox;
    // _openBoxWithRecovery 内部已包含 try-catch 和重建逻辑
    final box = await _openBoxWithRecovery(name);
    if (box == null) {
      // 最后兜底：完全重新初始化
      final ok = await _ensureInitialized();
      if (!ok) return null;
      // 再尝试一次
      return _openBoxWithRecovery(name);
    }
    return box;
  }

  /// 异步确保 Box 可用（fire-and-forget 模式，带错误捕获）
  /// - 用于同步读方法中检测到 Box 不可用时触发后台恢复
  /// - 必须带 catchError，否则任何未预期错误会泄漏成 zone 错误（导致崩溃弹窗）
  /// - onRecovered 回调在恢复成功时把 Box 写回对应 _xxBox 字段
  void _ensureBoxAsync(
    String name,
    Box? currentBox,
    void Function(Box?) onRecovered,
  ) {
    _ensureBox(name, currentBox).then(onRecovered).catchError((e) {
      debugPrint('❌ StorageService: _ensureBoxAsync($name) 失败: $e');
    });
  }

  /// 紧急重建所有 Box（用于 zone 错误兜底）
  /// - 关闭并删除所有 4 个 Box 文件，然后重新打开空 Box
  /// - 比单 Box 恢复更激进，只在检测到不可恢复的 HiveError 时使用
  /// - 内部所有步骤都有 try-catch，不会抛错
  /// - 用 _emergencyRecovering 标志防止并发触发
  bool _emergencyRecovering = false;

  Future<void> emergencyRecoverAll() async {
    if (_emergencyRecovering) {
      debugPrint('⚠️ StorageService: 紧急重建已在进行中，跳过重复触发');
      return;
    }
    _emergencyRecovering = true;
    debugPrint('🚨 StorageService: 紧急重建所有 Box');
    const names = ['settings', 'bookshelf', 'cache', 'bookSource'];
    for (final name in names) {
      try {
        await _safeCloseBox(name);
      } catch (_) {}
      try {
        if (await Hive.boxExists(name)) {
          await Hive.deleteBoxFromDisk(name);
        }
      } catch (_) {}
    }
    // 重新打开所有 Box（_openBoxWithRecovery 内部有 try-catch，不会抛错）
    _settingsBox = await _openBoxWithRecovery('settings');
    _bookshelfBox = await _openBoxWithRecovery('bookshelf');
    _cacheBox = await _openBoxWithRecovery('cache');
    _bookSourceBox = await _openBoxWithRecovery('bookSource');
    _initialized = _settingsBox != null;
    _emergencyRecovering = false;
    debugPrint('🚨 StorageService: 紧急重建完成 (initialized=$_initialized)');
  }

  Future<void> setSetting(String key, dynamic value) async {
    _settingsBox = await _ensureBox('settings', _settingsBox);
    if (_settingsBox == null) return;
    try {
      await _settingsBox!.put(key, value);
    } catch (e) {
      debugPrint('❌ StorageService: setSetting 写入失败: $e');
      _settingsBox = null;
      _recoverBoxAsync('settings', (box) => _settingsBox = box);
    }
  }

  dynamic getSetting(String key, {dynamic defaultValue}) {
    if (!_initialized) {
      debugPrint('⚠️ StorageService 未初始化，getSetting 返回默认值');
      return defaultValue;
    }
    if (_settingsBox == null || !_settingsBox!.isOpen) {
      debugPrint('⚠️ StorageService: settings Box不可用，尝试异步恢复');
      _ensureBoxAsync('settings', _settingsBox, (box) => _settingsBox = box);
      return defaultValue;
    }
    try {
      return _settingsBox!.get(key, defaultValue: defaultValue);
    } catch (e) {
      debugPrint('❌ StorageService: getSetting 读取失败: $e');
      _settingsBox = null;
      _recoverBoxAsync('settings', (box) => _settingsBox = box);
      return defaultValue;
    }
  }

  Future<void> addToBookshelf(Map<String, dynamic> bookData) async {
    final bookUrl =
        bookData['bookUrl'] as String? ?? bookData['id'] as String? ?? '';
    _bookshelfBox = await _ensureBox('bookshelf', _bookshelfBox);
    if (_bookshelfBox == null) return;
    try {
      await _bookshelfBox!.put(bookUrl, bookData);
    } catch (e) {
      debugPrint('❌ StorageService: addToBookshelf 写入失败: $e');
      _bookshelfBox = null;
      _recoverBoxAsync('bookshelf', (box) => _bookshelfBox = box);
    }
  }

  Future<void> removeFromBookshelf(String bookUrl) async {
    _bookshelfBox = await _ensureBox('bookshelf', _bookshelfBox);
    if (_bookshelfBox == null) return;
    try {
      await _bookshelfBox!.delete(bookUrl);
    } catch (e) {
      debugPrint('❌ StorageService: removeFromBookshelf 删除失败: $e');
      _bookshelfBox = null;
      _recoverBoxAsync('bookshelf', (box) => _bookshelfBox = box);
    }
  }

  List<Map<String, dynamic>> getAllBooks() {
    if (!_initialized) {
      debugPrint('⚠️ StorageService 未初始化，getAllBooks 返回空列表');
      return [];
    }
    if (_bookshelfBox == null || !_bookshelfBox!.isOpen) {
      debugPrint('⚠️ StorageService: bookshelf Box不可用，尝试异步恢复');
      _ensureBoxAsync('bookshelf', _bookshelfBox, (box) => _bookshelfBox = box);
      return [];
    }
    try {
      return _bookshelfBox!.values
          .where((e) => e is Map)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      debugPrint('❌ StorageService: getAllBooks 读取失败: $e');
      _bookshelfBox = null;
      _recoverBoxAsync('bookshelf', (box) => _bookshelfBox = box);
      return [];
    }
  }

  Map<String, dynamic>? getBook(String bookUrl) {
    if (!_initialized) {
      debugPrint('⚠️ StorageService 未初始化，getBook 返回 null');
      return null;
    }
    if (_bookshelfBox == null || !_bookshelfBox!.isOpen) {
      debugPrint('⚠️ StorageService: bookshelf Box不可用，尝试异步恢复');
      _ensureBoxAsync('bookshelf', _bookshelfBox, (box) => _bookshelfBox = box);
      return null;
    }
    dynamic data;
    try {
      data = _bookshelfBox!.get(bookUrl);
    } catch (e) {
      debugPrint('❌ StorageService: getBook 读取失败: $e');
      _bookshelfBox = null;
      _recoverBoxAsync('bookshelf', (box) => _bookshelfBox = box);
      return null;
    }
    if (data == null) return null;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    debugPrint('⚠️ StorageService: bookshelf 数据类型异常: ${data.runtimeType}');
    return null;
  }

  Future<void> updateBookProgress(
    String bookUrl,
    int durChapterIndex,
    String durChapterTitle,
    int durChapterPos,
  ) async {
    _bookshelfBox = await _ensureBox('bookshelf', _bookshelfBox);
    if (_bookshelfBox == null) return;
    dynamic rawBook;
    try {
      rawBook = _bookshelfBox!.get(bookUrl);
    } catch (e) {
      debugPrint('❌ StorageService: updateBookProgress 读取失败: $e');
      _bookshelfBox = null;
      _recoverBoxAsync('bookshelf', (box) => _bookshelfBox = box);
      return;
    }
    final book = rawBook is Map ? Map<String, dynamic>.from(rawBook) : null;
    if (book != null) {
      book['durChapterIndex'] = durChapterIndex;
      book['durChapterTitle'] = durChapterTitle;
      book['durChapterPos'] = durChapterPos;
      book['durChapterTime'] = DateTime.now().toIso8601String();
      try {
        await _bookshelfBox!.put(bookUrl, book);
      } catch (e) {
        debugPrint('❌ StorageService: updateBookProgress 写入失败: $e');
        _bookshelfBox = null;
        _recoverBoxAsync('bookshelf', (box) => _bookshelfBox = box);
      }
    }
  }

  Future<void> saveBook(dynamic book) async {
    Map<String, dynamic> data;
    if (book is Map<String, dynamic>) {
      data = book;
    } else {
      data = (book as dynamic).toJson() as Map<String, dynamic>;
    }
    final bookUrl = data['bookUrl'] as String? ?? '';
    _bookshelfBox = await _ensureBox('bookshelf', _bookshelfBox);
    if (_bookshelfBox == null) return;
    try {
      await _bookshelfBox!.put(bookUrl, data);
    } catch (e) {
      debugPrint('❌ StorageService: saveBook 写入失败: $e');
      _bookshelfBox = null;
      _recoverBoxAsync('bookshelf', (box) => _bookshelfBox = box);
    }
  }

  Future<void> saveBookSource(Map<String, dynamic> sourceData) async {
    final sourceUrl = sourceData['bookSourceUrl'] as String? ?? '';
    if (sourceUrl.isEmpty) {
      debugPrint('⚠️ StorageService: 书源URL为空，跳过保存');
      return;
    }

    // 确保 Box 可用
    _bookSourceBox = await _ensureBox('bookSource', _bookSourceBox);
    if (_bookSourceBox == null) {
      // 最后一次尝试：完全重新初始化
      final ok = await _ensureInitialized();
      if (!ok) {
        debugPrint('❌ StorageService: 初始化失败，无法保存书源: $sourceUrl');
        // 不抛异常，触发紧急重建由 zone 兜底
        emergencyRecoverAll().catchError((e) {
          debugPrint('❌ StorageService: 紧急重建失败: $e');
        });
        return;
      }
    }

    try {
      await _bookSourceBox!.put(sourceUrl, sourceData);
      await _bookSourceBox!.flush();
      debugPrint('✅ 书源保存成功: $sourceUrl');
    } catch (e) {
      debugPrint('❌ 书源写入失败: $e，尝试重建 Box...');
      // 重建 Box：用 _openBoxWithRecovery 走完整 healthCheck 流程
      _bookSourceBox = null;
      _bookSourceBox = await _openBoxWithRecovery('bookSource');
      if (_bookSourceBox == null) {
        debugPrint('❌ StorageService: bookSource 重建失败，放弃保存: $sourceUrl');
        // 不抛异常，避免逃逸到 zone
        return;
      }
      try {
        await _bookSourceBox!.put(sourceUrl, sourceData);
        await _bookSourceBox!.flush();
        debugPrint('✅ 书源重建后保存成功: $sourceUrl');
      } catch (e2) {
        debugPrint('❌ StorageService: 重建后仍保存失败: $sourceUrl - $e2');
        // 不抛异常，避免逃逸到 zone
      }
    }
  }

  Future<void> saveBookSources(List<Map<String, dynamic>> sources) async {
    for (final source in sources) {
      await saveBookSource(source);
    }
  }

  List<Map<String, dynamic>> getAllBookSources() {
    if (!_initialized) {
      debugPrint('⚠️ StorageService 未初始化，getAllBookSources 返回空列表');
      return [];
    }
    if (_bookSourceBox == null || !_bookSourceBox!.isOpen) {
      debugPrint('⚠️ StorageService: bookSource Box不可用，尝试异步恢复');
      _ensureBoxAsync(
        'bookSource',
        _bookSourceBox,
        (box) => _bookSourceBox = box,
      );
      return [];
    }
    try {
      return _bookSourceBox!.values
          .where((e) => e is Map)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      debugPrint('❌ StorageService: getAllBookSources 读取失败: $e');
      _bookSourceBox = null;
      _recoverBoxAsync('bookSource', (box) => _bookSourceBox = box);
      return [];
    }
  }

  Map<String, dynamic>? getBookSource(String sourceUrl) {
    if (!_initialized) {
      debugPrint('⚠️ StorageService 未初始化，getBookSource 返回 null');
      return null;
    }
    if (_bookSourceBox == null || !_bookSourceBox!.isOpen) {
      debugPrint('⚠️ StorageService: bookSource Box不可用，尝试异步恢复');
      _ensureBoxAsync(
        'bookSource',
        _bookSourceBox,
        (box) => _bookSourceBox = box,
      );
      return null;
    }
    dynamic data;
    try {
      data = _bookSourceBox!.get(sourceUrl);
    } catch (e) {
      debugPrint('❌ StorageService: getBookSource 读取失败: $e');
      _bookSourceBox = null;
      _recoverBoxAsync('bookSource', (box) => _bookSourceBox = box);
      return null;
    }
    if (data == null) return null;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    debugPrint('⚠️ StorageService: bookSource 数据类型异常: ${data.runtimeType}');
    return null;
  }

  Future<void> deleteBookSource(String sourceUrl) async {
    _bookSourceBox = await _ensureBox('bookSource', _bookSourceBox);
    if (_bookSourceBox == null) return;
    try {
      await _bookSourceBox!.delete(sourceUrl);
    } catch (e) {
      debugPrint('❌ StorageService: deleteBookSource 删除失败: $e');
      _bookSourceBox = null;
      _recoverBoxAsync('bookSource', (box) => _bookSourceBox = box);
    }
  }

  Future<void> clearBookSources() async {
    _bookSourceBox = await _ensureBox('bookSource', _bookSourceBox);
    if (_bookSourceBox == null) return;
    try {
      await _bookSourceBox!.clear();
    } catch (e) {
      debugPrint('❌ StorageService: clearBookSources 清空失败: $e');
      _bookSourceBox = null;
      _recoverBoxAsync('bookSource', (box) => _bookSourceBox = box);
    }
  }

  Future<void> cacheData(String key, dynamic data) async {
    _cacheBox = await _ensureBox('cache', _cacheBox);
    if (_cacheBox == null) return;
    try {
      await _cacheBox!.put(key, data);
    } catch (e) {
      debugPrint('❌ StorageService: cacheData 写入失败: $e');
      _cacheBox = null;
      _recoverBoxAsync('cache', (box) => _cacheBox = box);
    }
  }

  dynamic getCachedData(String key) {
    if (!_initialized) {
      debugPrint('⚠️ StorageService 未初始化，getCachedData 返回 null');
      return null;
    }
    if (_cacheBox == null || !_cacheBox!.isOpen) {
      _ensureBoxAsync('cache', _cacheBox, (box) => _cacheBox = box);
      return null;
    }
    try {
      return _cacheBox!.get(key);
    } catch (e) {
      debugPrint('❌ StorageService: getCachedData 读取失败: $e');
      _cacheBox = null;
      _recoverBoxAsync('cache', (box) => _cacheBox = box);
      return null;
    }
  }

  Future<dynamic> getCachedDataAsync(String key) async {
    _cacheBox = await _ensureBox('cache', _cacheBox);
    try {
      return _cacheBox?.get(key);
    } catch (e) {
      debugPrint('❌ StorageService: getCachedDataAsync 读取失败: $e');
      await _recoverBox('cache', (box) => _cacheBox = box);
      return null;
    }
  }

  Future<void> clearCache() async {
    _cacheBox = await _ensureBox('cache', _cacheBox);
    if (_cacheBox == null) return;
    try {
      await _cacheBox!.clear();
    } catch (e) {
      debugPrint('❌ StorageService: clearCache 清空失败: $e');
      _cacheBox = null;
      _recoverBoxAsync('cache', (box) => _cacheBox = box);
    }
  }

  Future<void> saveReaderConfig(Map<String, dynamic> config) async {
    _settingsBox = await _ensureBox('settings', _settingsBox);
    if (_settingsBox == null) return;
    try {
      await _settingsBox!.put('readerConfig', config);
    } catch (e) {
      debugPrint('❌ StorageService: saveReaderConfig 写入失败: $e');
      _settingsBox = null;
      _recoverBoxAsync('settings', (box) => _settingsBox = box);
    }
  }

  Map<String, dynamic>? getReaderConfig() {
    if (!_initialized) {
      debugPrint('⚠️ StorageService 未初始化，getReaderConfig 返回 null');
      return null;
    }
    if (_settingsBox == null || !_settingsBox!.isOpen) {
      _ensureBoxAsync('settings', _settingsBox, (box) => _settingsBox = box);
      return null;
    }
    dynamic data;
    try {
      data = _settingsBox!.get('readerConfig');
    } catch (e) {
      debugPrint('❌ StorageService: getReaderConfig 读取失败: $e');
      _settingsBox = null;
      _recoverBoxAsync('settings', (box) => _settingsBox = box);
      return null;
    }
    if (data == null) return null;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    debugPrint('⚠️ StorageService: readerConfig 数据类型异常: ${data.runtimeType}');
    return null;
  }

  Future<void> saveLegadoUrl(String url) async {
    _settingsBox = await _ensureBox('settings', _settingsBox);
    if (_settingsBox == null) return;
    try {
      await _settingsBox!.put('legadoUrl', url);
    } catch (e) {
      debugPrint('❌ StorageService: saveLegadoUrl 写入失败: $e');
      _settingsBox = null;
      _recoverBoxAsync('settings', (box) => _settingsBox = box);
    }
  }

  String? getLegadoUrl() {
    if (!_initialized) {
      debugPrint('⚠️ StorageService 未初始化，getLegadoUrl 返回 null');
      return null;
    }
    if (_settingsBox == null || !_settingsBox!.isOpen) {
      _ensureBoxAsync('settings', _settingsBox, (box) => _settingsBox = box);
      return null;
    }
    try {
      return _settingsBox!.get('legadoUrl');
    } catch (e) {
      debugPrint('❌ StorageService: getLegadoUrl 读取失败: $e');
      _settingsBox = null;
      _recoverBoxAsync('settings', (box) => _settingsBox = box);
      return null;
    }
  }

  // 高亮相关方法
  Future<void> saveHighlight(Map<String, dynamic> highlightData) async {
    final id = highlightData['id'] as String? ?? '';
    _cacheBox = await _ensureBox('cache', _cacheBox);
    if (_cacheBox == null) return;
    try {
      await _cacheBox!.put('highlight_$id', highlightData);
    } catch (e) {
      debugPrint('❌ StorageService: saveHighlight 写入失败: $e');
      _cacheBox = null;
      _recoverBoxAsync('cache', (box) => _cacheBox = box);
    }
  }

  Future<void> deleteHighlight(String id) async {
    _cacheBox = await _ensureBox('cache', _cacheBox);
    if (_cacheBox == null) return;
    try {
      await _cacheBox!.delete('highlight_$id');
    } catch (e) {
      debugPrint('❌ StorageService: deleteHighlight 删除失败: $e');
      _cacheBox = null;
      _recoverBoxAsync('cache', (box) => _cacheBox = box);
    }
  }

  List<Map<String, dynamic>> getChapterHighlights(
    String bookUrl,
    int chapterIndex,
  ) {
    if (!_initialized) {
      debugPrint('⚠️ StorageService 未初始化，getChapterHighlights 返回空列表');
      return [];
    }
    if (_cacheBox == null || !_cacheBox!.isOpen) {
      _ensureBoxAsync('cache', _cacheBox, (box) => _cacheBox = box);
      return [];
    }
    try {
      return _cacheBox!.values
          .where((e) {
            if (e is! Map) return false;
            return e['bookUrl'] == bookUrl && e['chapterIndex'] == chapterIndex;
          })
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      debugPrint('❌ StorageService: getChapterHighlights 读取失败: $e');
      _cacheBox = null;
      _recoverBoxAsync('cache', (box) => _cacheBox = box);
      return [];
    }
  }

  List<Map<String, dynamic>> getAllHighlights(String bookUrl) {
    if (!_initialized) {
      debugPrint('⚠️ StorageService 未初始化，getAllHighlights 返回空列表');
      return [];
    }
    if (_cacheBox == null || !_cacheBox!.isOpen) {
      _ensureBoxAsync('cache', _cacheBox, (box) => _cacheBox = box);
      return [];
    }
    try {
      return _cacheBox!.values
          .where((e) {
            if (e is! Map) return false;
            return e['bookUrl'] == bookUrl;
          })
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      debugPrint('❌ StorageService: getAllHighlights 读取失败: $e');
      _cacheBox = null;
      _recoverBoxAsync('cache', (box) => _cacheBox = box);
      return [];
    }
  }

  // 高亮规则相关方法
  Future<void> saveHighlightRule(Map<String, dynamic> ruleData) async {
    final id = ruleData['id'] as String? ?? '';
    _settingsBox = await _ensureBox('settings', _settingsBox);
    if (_settingsBox == null) return;
    try {
      await _settingsBox!.put('highlightRule_$id', ruleData);
    } catch (e) {
      debugPrint('❌ StorageService: saveHighlightRule 写入失败: $e');
      _settingsBox = null;
      _recoverBoxAsync('settings', (box) => _settingsBox = box);
    }
  }

  Future<void> deleteHighlightRule(String id) async {
    _settingsBox = await _ensureBox('settings', _settingsBox);
    if (_settingsBox == null) return;
    try {
      await _settingsBox!.delete('highlightRule_$id');
    } catch (e) {
      debugPrint('❌ StorageService: deleteHighlightRule 删除失败: $e');
      _settingsBox = null;
      _recoverBoxAsync('settings', (box) => _settingsBox = box);
    }
  }

  List<Map<String, dynamic>> getAllHighlightRules() {
    if (!_initialized) {
      debugPrint('⚠️ StorageService 未初始化，getAllHighlightRules 返回空列表');
      return [];
    }
    if (_settingsBox == null) return [];
    try {
      return _settingsBox!.values
          .where((e) {
            if (e is! Map) return false;
            return e.containsKey('pattern');
          })
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      debugPrint('❌ StorageService: getAllHighlightRules 读取失败: $e');
      _settingsBox = null;
      _recoverBoxAsync('settings', (box) => _settingsBox = box);
      return [];
    }
  }
}
