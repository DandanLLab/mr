import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class VideoPlayerPage extends StatefulWidget {
  final String bookId;
  final String episodeId;

  const VideoPlayerPage({
    super.key,
    required this.bookId,
    required this.episodeId,
  });

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  VideoPlayerController? _controller;
  bool _isPlaying = false;
  final bool _showControls = true;
  int _currentEpisodeIndex = 0;
  final int _totalEpisodes = 24;
  String _episodeTitle = '';
  double _playbackSpeed = 1.0;

  @override
  void initState() {
    super.initState();
    _loadEpisode();
  }

  Future<void> _loadEpisode() async {
    setState(() {
      _episodeTitle = '第${_currentEpisodeIndex + 1}集';
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          _buildVideoPlayer(),
          if (_showControls) _buildControls(),
        ],
      ),
    );
  }

  Widget _buildVideoPlayer() {
    return Center(
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          color: Colors.black,
          child: const Center(
            child: Icon(
              Icons.play_circle_outline,
              size: 80,
              color: Colors.white54,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Column(
      children: [
        _buildTopBar(),
        const Spacer(),
        _buildCenterControls(),
        const Spacer(),
        _buildBottomControls(),
      ],
    );
  }

  Widget _buildTopBar() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.7),
            Colors.transparent,
          ],
        ),
      ),
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            Expanded(
              child: Text(
                _episodeTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.list, color: Colors.white),
              onPressed: _showEpisodeList,
            ),
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.white),
              onPressed: _showSettings,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCenterControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.replay_10, color: Colors.white, size: 36),
          onPressed: _rewind,
        ),
        const SizedBox(width: 32),
        GestureDetector(
          onTap: _togglePlay,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _isPlaying ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
              size: 48,
            ),
          ),
        ),
        const SizedBox(width: 32),
        IconButton(
          icon: const Icon(Icons.forward_10, color: Colors.white, size: 36),
          onPressed: _forward,
        ),
      ],
    );
  }

  Widget _buildBottomControls() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.black.withValues(alpha: 0.7),
            Colors.transparent,
          ],
        ),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildProgressBar(),
            _buildBottomButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressBar() {
    // 局部变量捕获：避免 build 过程中 _controller 被置 null
    final controller = _controller;
    final initialized = controller != null && controller.value.isInitialized;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text(
            initialized
                ? _formatDuration(controller.value.position)
                : '00:00',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          Expanded(
            child: Slider(
              value: initialized
                  ? controller.value.position.inMilliseconds
                      .toDouble()
                      .clamp(0, controller.value.duration.inMilliseconds
                          .toDouble())
                  : 0,
              min: 0,
              max: initialized
                  ? controller.value.duration.inMilliseconds.toDouble()
                  : 100,
              activeColor: Colors.white,
              inactiveColor: Colors.white24,
              onChanged: initialized
                  ? (value) {
                      controller.seekTo(
                        Duration(milliseconds: value.toInt()),
                      );
                    }
                  : null,
            ),
          ),
          Text(
            initialized
                ? _formatDuration(controller.value.duration)
                : '00:00',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          TextButton.icon(
            onPressed: _previousEpisode,
            icon: const Icon(Icons.skip_previous, color: Colors.white),
            label: const Text('上一集', style: TextStyle(color: Colors.white)),
          ),
          TextButton.icon(
            onPressed: _nextEpisode,
            icon: const Icon(Icons.skip_next, color: Colors.white),
            label: const Text('下一集', style: TextStyle(color: Colors.white)),
          ),
          TextButton.icon(
            onPressed: _showSpeedDialog,
            icon: const Icon(Icons.speed, color: Colors.white),
            label: Text(
              '${_playbackSpeed}x',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  void _togglePlay() {
    // 局部变量捕获：避免 setState 期间 _controller 被置 null
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('视频未加载，无法播放'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }
    setState(() {
      _isPlaying = !_isPlaying;
      if (_isPlaying) {
        controller.play();
      } else {
        controller.pause();
      }
    });
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _rewind() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final position = controller.value.position;
    final newPosition = position - const Duration(seconds: 10);
    controller.seekTo(newPosition < Duration.zero ? Duration.zero : newPosition);
  }

  void _forward() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final position = controller.value.position;
    final duration = controller.value.duration;
    final newPosition = position + const Duration(seconds: 10);
    controller.seekTo(newPosition > duration ? duration : newPosition);
  }

  void _previousEpisode() {
    if (_currentEpisodeIndex > 0) {
      setState(() {
        _currentEpisodeIndex--;
      });
      _loadEpisode();
    }
  }

  void _nextEpisode() {
    if (_currentEpisodeIndex < _totalEpisodes - 1) {
      setState(() {
        _currentEpisodeIndex++;
      });
      _loadEpisode();
    }
  }

  void _showEpisodeList() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (context) {
        return SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '选集',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                      ),
                ),
              ),
              const Divider(color: Colors.white24),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 2,
                  ),
                  itemCount: _totalEpisodes,
                  itemBuilder: (context, index) {
                    final isSelected = index == _currentEpisodeIndex;
                    return InkWell(
                      onTap: () {
                        setState(() {
                          _currentEpisodeIndex = index;
                        });
                        _loadEpisode();
                        Navigator.pop(context);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Theme.of(context).colorScheme.primary
                              : Colors.white24,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Text(
                            '${index + 1}',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.hd, color: Colors.white),
                title: const Text('画质', style: TextStyle(color: Colors.white)),
                subtitle: const Text('高清 720P',
                    style: TextStyle(color: Colors.white54)),
                onTap: () {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('画质切换功能开发中'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.router, color: Colors.white),
                title: const Text('线路', style: TextStyle(color: Colors.white)),
                subtitle: const Text('线路1',
                    style: TextStyle(color: Colors.white54)),
                onTap: () {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('线路切换功能开发中'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.download, color: Colors.white),
                title: const Text('缓存本集', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('缓存功能开发中'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSpeedDialog() {
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('播放速度'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: speeds.map((speed) {
              return RadioListTile<double>(
                title: Text('${speed}x'),
                value: speed,
                groupValue: _playbackSpeed,
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _playbackSpeed = value;
                      _controller?.setPlaybackSpeed(value);
                    });
                    Navigator.pop(context);
                  }
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }
}
