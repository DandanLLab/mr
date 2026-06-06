import 'package:flutter/material.dart';

class AudioPlayerPage extends StatefulWidget {
  final String bookId;
  final String trackId;

  const AudioPlayerPage({
    super.key,
    required this.bookId,
    required this.trackId,
  });

  @override
  State<AudioPlayerPage> createState() => _AudioPlayerPageState();
}

class _AudioPlayerPageState extends State<AudioPlayerPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  bool _isPlaying = false;
  int _currentTrackIndex = 0;
  final int _totalTracks = 30;
  String _trackTitle = '';
  final String _albumTitle = '示例专辑';
  Duration _currentPosition = Duration.zero;
  final Duration _totalDuration = const Duration(minutes: 5);
  double _volume = 1.0;
  int _timerMinutes = 0;
  // ignore: unused_field
  bool _isTimerActive = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    );
    _loadTrack();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _loadTrack() async {
    setState(() {
      _trackTitle = '第${_currentTrackIndex + 1}首 - 音频标题';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('正在播放'),
        actions: [
          IconButton(
            icon: const Icon(Icons.timer),
            onPressed: _showTimerDialog,
          ),
          IconButton(
            icon: const Icon(Icons.playlist_play),
            onPressed: _showPlaylist,
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 32),
              _buildAlbumCover(),
              const SizedBox(height: 32),
              _buildTrackInfo(),
              const SizedBox(height: 24),
              _buildProgressBar(),
              const SizedBox(height: 24),
              _buildControls(),
              const SizedBox(height: 32),
              _buildVolumeControl(),
              const SizedBox(height: 24),
              _buildActionButtons(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAlbumCover() {
    return ListenableBuilder(
      listenable: _animationController,
      builder: (context, child) {
        return Transform.rotate(
          angle: _animationController.value * 2 * 3.14159,
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                  blurRadius: 30,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: ClipOval(
              child: Container(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Icon(
                  Icons.music_note,
                  size: 80,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTrackInfo() {
    return Column(
      children: [
        Text(
          _trackTitle,
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          _albumTitle,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildProgressBar() {
    return Column(
      children: [
        Slider(
          value: _currentPosition.inSeconds.toDouble(),
          min: 0,
          max: _totalDuration.inSeconds.toDouble(),
          onChanged: (value) {
            setState(() {
              _currentPosition = Duration(seconds: value.toInt());
            });
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatDuration(_currentPosition)),
              Text(_formatDuration(_totalDuration)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.skip_previous, size: 36),
          onPressed: _previousTrack,
        ),
        const SizedBox(width: 24),
        GestureDetector(
          onTap: _togglePlay,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
            ),
            child: Icon(
              _isPlaying ? Icons.pause : Icons.play_arrow,
              color: Theme.of(context).colorScheme.onPrimary,
              size: 40,
            ),
          ),
        ),
        const SizedBox(width: 24),
        IconButton(
          icon: const Icon(Icons.skip_next, size: 36),
          onPressed: _nextTrack,
        ),
      ],
    );
  }

  Widget _buildVolumeControl() {
    return Row(
      children: [
        const Icon(Icons.volume_down),
        Expanded(
          child: Slider(
            value: _volume,
            min: 0,
            max: 1,
            onChanged: (value) {
              setState(() {
                _volume = value;
              });
            },
          ),
        ),
        const Icon(Icons.volume_up),
      ],
    );
  }

  Widget _buildActionButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildActionButton(
          icon: Icons.download,
          label: '缓存',
          onTap: () {},
        ),
        _buildActionButton(
          icon: Icons.share,
          label: '分享',
          onTap: () {},
        ),
        _buildActionButton(
          icon: Icons.favorite_border,
          label: '收藏',
          onTap: () {},
        ),
      ],
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          Icon(icon),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _togglePlay() {
    setState(() {
      _isPlaying = !_isPlaying;
      if (_isPlaying) {
        _animationController.repeat();
      } else {
        _animationController.stop();
      }
    });
  }

  void _previousTrack() {
    if (_currentTrackIndex > 0) {
      setState(() {
        _currentTrackIndex--;
        _currentPosition = Duration.zero;
      });
      _loadTrack();
    }
  }

  void _nextTrack() {
    if (_currentTrackIndex < _totalTracks - 1) {
      setState(() {
        _currentTrackIndex++;
        _currentPosition = Duration.zero;
      });
      _loadTrack();
    }
  }

  void _showTimerDialog() {
    final options = [15, 30, 60, 90, 120];

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('定时停止'),
          content: RadioGroup<int>(
            groupValue: _timerMinutes,
            onChanged: (value) {
              setState(() {
                _timerMinutes = value!;
                _isTimerActive = value != 0;
              });
              Navigator.pop(context);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...options.map((minutes) {
                  return RadioListTile<int>(
                    title: Text('$minutes 分钟'),
                    value: minutes,
                  );
                }),
                RadioListTile<int>(
                  title: const Text('关闭'),
                  value: 0,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showPlaylist() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) {
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '播放列表 ($_totalTracks)',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      TextButton(
                        onPressed: () {},
                        child: const Text('缓存全部'),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: _totalTracks,
                    itemBuilder: (context, index) {
                      final isSelected = index == _currentTrackIndex;
                      return ListTile(
                        leading: isSelected
                            ? Icon(
                                Icons.play_circle_filled,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : const Icon(Icons.music_note),
                        title: Text('第${index + 1}首 - 音频标题'),
                        subtitle: const Text('05:00'),
                        selected: isSelected,
                        onTap: () {
                          setState(() {
                            _currentTrackIndex = index;
                            _currentPosition = Duration.zero;
                          });
                          _loadTrack();
                          Navigator.pop(context);
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
