import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../bookshelf/bookshelf_page.dart';
import '../discovery/discovery_page.dart';
import '../miniprogram/miniprogram_page.dart';
import '../profile/profile_page.dart';
import '../../providers/bookshelf_provider.dart';
import '../../providers/discovery_provider.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  int _currentIndex = 0;
  bool _isLoading = true;
  String? _error;
  late PageController _pageController;
  
  // 导航栏配置
  String _layoutMode = 'floating'; // floating, standard, sidebar
  String _sidebarGravity = 'start'; // start, end
  bool _showSearchButton = false;  // 默认不显示搜索按钮
  
  // 侧边栏状态
  bool _sidebarOpen = false;
  
  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 0);
    _loadData();
    _requestPermissions();
    _loadNavConfig();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }
  
  Future<void> _loadNavConfig() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _layoutMode = prefs.getString('navLayoutMode') ?? 'floating';
      _sidebarGravity = prefs.getString('navSidebarGravity') ?? 'start';
      _showSearchButton = prefs.getBool('navShowSearchButton') ?? false;
    });
  }
  
  void _navigateToDiscovery() {
    _pageController.animateToPage(
      1,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _requestPermissions() async {
    if (kIsWeb || !Platform.isAndroid) return;

    try {
      await [
        Permission.notification,
      ].request();
    } catch (e) {
      debugPrint('⚠️ 权限请求异常: $e');
    }
  }

  Future<void> _loadData() async {
    try {
      await context.read<BookshelfProvider>().loadBooks();
      await context.read<DiscoveryProvider>().loadBookSources();
      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  void _toggleSidebar() {
    setState(() {
      _sidebarOpen = !_sidebarOpen;
    });
  }

  void _closeSidebar() {
    if (_sidebarOpen) {
      setState(() {
        _sidebarOpen = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              const Text('正在加载...'),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text('加载失败: $_error'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _isLoading = true;
                    _error = null;
                  });
                  _loadData();
                },
                child: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );
    }

    // 侧边栏模式
    if (_layoutMode == 'sidebar') {
      return _buildSidebarLayout();
    }

    // 标准模式
    if (_layoutMode == 'standard') {
      return _buildStandardLayout();
    }

    // 悬浮模式（默认）
    return _buildFloatingLayout();
  }

  /// 悬浮模式布局 - 玻璃效果 + 悬浮导航栏
  Widget _buildFloatingLayout() {
    final pages = [
      BookshelfPage(onSwipeToNext: _navigateToDiscovery),
      const DiscoveryPage(),
      const MiniprogramPage(),
      const ProfilePage(),
    ];

    return Scaffold(
      body: Stack(
        children: [
          // 主内容
          PageView(
            controller: _pageController,
            onPageChanged: (index) {
              setState(() {
                _currentIndex = index;
              });
            },
            children: pages,
          ),
          // 底部导航栏
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildFloatingNavBar(),
          ),
        ],
      ),
    );
  }

  Widget _buildFloatingNavBar() {
    // 参考 legado-main 的精确尺寸
    // main_bottom_bar_height: 48dp
    // main_bottom_bar_corner_radius: 24dp
    // main_bottom_controls_horizontal_padding: 20dp
    // main_bottom_controls_bottom_padding: 10dp
    // main_bottom_nav_icon_size: 23dp
    // main_bottom_bar_gap: 10dp
    // main_bottom_bar_elevation: 12dp
    
    final bottomBarHeight = 48.0;
    final cornerRadius = 24.0;
    final horizontalPadding = 20.0;
    final bottomPadding = 10.0;
    final iconSize = 23.0;
    final barGap = 10.0;
    final elevation = 12.0;
    
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = colorScheme.brightness == Brightness.dark;
    
    return Padding(
      padding: EdgeInsets.only(
        left: horizontalPadding,
        right: horizontalPadding,
        bottom: bottomPadding,
      ),
      child: Row(
        children: [
          // 导航栏主体
          Expanded(
            child: Material(
              elevation: elevation,
              borderRadius: BorderRadius.circular(cornerRadius),
              color: Colors.transparent,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(cornerRadius),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    height: bottomBarHeight,
                    decoration: BoxDecoration(
                      color: isDark 
                        ? colorScheme.surface.withOpacity(0.85)
                        : colorScheme.surface.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(cornerRadius),
                      border: Border.all(
                        color: isDark 
                          ? Colors.white.withOpacity(0.08)
                          : Colors.black.withOpacity(0.04),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildNavItem(0, Icons.book_outlined, Icons.book, iconSize, '书架'),
                        _buildNavItem(1, Icons.explore_outlined, Icons.explore, iconSize, '发现'),
                        _buildNavItem(2, Icons.apps_outlined, Icons.apps, iconSize, '小程序'),
                        _buildNavItem(3, Icons.person_outline, Icons.person, iconSize, '我的'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 搜索按钮（分离）
          if (_showSearchButton) ...[
            SizedBox(width: barGap),
            _buildSearchButton(cornerRadius, elevation),
          ],
        ],
      ),
    );
  }

  Widget _buildSearchButton(double cornerRadius, double elevation) {
    // main_search_button_size: 48dp
    // main_search_button_icon_size: 22dp
    // main_search_button_elevation: 14dp
    
    final buttonSize = 48.0;
    final searchIconSize = 22.0;
    final searchElevation = 14.0;
    
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = colorScheme.brightness == Brightness.dark;
    
    return Tooltip(
      message: '搜索',
      child: Material(
        elevation: searchElevation,
        borderRadius: BorderRadius.circular(buttonSize / 2),
        color: Colors.transparent,
        child: ClipOval(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              width: buttonSize,
              height: buttonSize,
              decoration: BoxDecoration(
                color: isDark 
                  ? colorScheme.surface.withOpacity(0.85)
                  : colorScheme.surface.withOpacity(0.9),
                shape: BoxShape.circle,
                border: Border.all(
                  color: isDark 
                    ? Colors.white.withOpacity(0.08)
                    : Colors.black.withOpacity(0.04),
                  width: 1,
                ),
              ),
              child: Icon(
                Icons.search,
                size: searchIconSize,
                color: colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, IconData activeIcon, double iconSize, String label) {
    final isSelected = _currentIndex == index;
    final colorScheme = Theme.of(context).colorScheme;
    
    return Expanded(
      child: Tooltip(
        message: label,
        child: GestureDetector(
          onTap: () {
            if (_currentIndex != index) {
              _pageController.animateToPage(
                index,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
              );
            }
          },
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 48,
            alignment: Alignment.center,
            child: Icon(
              isSelected ? activeIcon : icon,
              size: iconSize,
              color: isSelected 
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  /// 标准模式布局 - 传统底部导航栏
  Widget _buildStandardLayout() {
    final pages = [
      BookshelfPage(onSwipeToNext: _navigateToDiscovery),
      const DiscoveryPage(),
      const MiniprogramPage(),
      const ProfilePage(),
    ];

    return Scaffold(
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        children: pages,
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top: BorderSide(
              color: Theme.of(context).dividerColor.withOpacity(0.2),
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildStandardNavItem(0, Icons.book_outlined, Icons.book, '书架'),
            _buildStandardNavItem(1, Icons.explore_outlined, Icons.explore, '发现'),
            _buildStandardNavItem(2, Icons.apps_outlined, Icons.apps, '小程序'),
            _buildStandardNavItem(3, Icons.person_outline, Icons.person, '我的'),
          ],
        ),
      ),
    );
  }

  Widget _buildStandardNavItem(int index, IconData icon, IconData activeIcon, String label) {
    final isSelected = _currentIndex == index;
    final colorScheme = Theme.of(context).colorScheme;
    
    return Tooltip(
      message: label,
      child: GestureDetector(
        onTap: () {
          _pageController.animateToPage(
            index,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        },
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isSelected ? activeIcon : icon,
                size: 24,
                color: isSelected 
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: isSelected 
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 侧边栏模式布局
  Widget _buildSidebarLayout() {
    final pages = [
      BookshelfPage(onSwipeToNext: _navigateToDiscovery),
      const DiscoveryPage(),
      const MiniprogramPage(),
      const ProfilePage(),
    ];

    return Scaffold(
      body: Stack(
        children: [
          // 主内容
          PageView(
            controller: _pageController,
            onPageChanged: (index) {
              setState(() {
                _currentIndex = index;
              });
            },
            children: pages,
          ),
          // 侧边栏遮罩
          if (_sidebarOpen)
            GestureDetector(
              onTap: _closeSidebar,
              child: Container(
                color: Colors.black.withOpacity(0.5),
                width: double.infinity,
                height: double.infinity,
              ),
            ),
          // 侧边栏
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            left: _sidebarGravity == 'start' 
              ? (_sidebarOpen ? 0 : -280)
              : null,
            right: _sidebarGravity == 'end'
              ? (_sidebarOpen ? 0 : -280)
              : null,
            top: 0,
            bottom: 0,
            child: _buildSidebar(),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = colorScheme.brightness == Brightness.dark;
    
    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 20,
            spreadRadius: 5,
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          children: [
            // 头部
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withOpacity(0.3),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: colorScheme.primary,
                    child: Icon(Icons.person, color: colorScheme.onPrimary),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '用户名',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: colorScheme.onSurface,
                          ),
                        ),
                        Text(
                          '今日阅读: 30分钟',
                          style: TextStyle(
                            fontSize: 14,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 导航项
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  _buildSidebarItem(0, Icons.book, '书架'),
                  _buildSidebarItem(1, Icons.explore, '发现'),
                  _buildSidebarItem(2, Icons.apps, '小程序'),
                  _buildSidebarItem(3, Icons.person, '我的'),
                  const Divider(),
                  _buildSidebarItem(4, Icons.settings, '设置'),
                  _buildSidebarItem(5, Icons.info, '关于'),
                ],
              ),
            ),
            // 底部搜索
            Container(
              padding: const EdgeInsets.all(16),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: isDark 
                    ? Colors.white.withOpacity(0.1)
                    : Colors.black.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.search, color: colorScheme.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Text(
                      '搜索',
                      style: TextStyle(color: colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebarItem(int index, IconData icon, String label) {
    final isSelected = _currentIndex == index && index < 4;
    final colorScheme = Theme.of(context).colorScheme;
    
    return Tooltip(
      message: label,
      child: ListTile(
        leading: Icon(
          icon,
          color: isSelected ? colorScheme.primary : colorScheme.onSurfaceVariant,
        ),
        title: Text(
          label,
          style: TextStyle(
            color: isSelected ? colorScheme.primary : colorScheme.onSurface,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        selected: isSelected,
        selectedTileColor: colorScheme.primaryContainer.withOpacity(0.3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        onTap: () {
          if (index < 4) {
            _pageController.animateToPage(
              index,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
            );
            _closeSidebar();
          } else if (index == 4) {
            Navigator.pushNamed(context, '/settings');
            _closeSidebar();
          } else if (index == 5) {
            Navigator.pushNamed(context, '/about');
            _closeSidebar();
          }
        },
      ),
    );
  }
}
