import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/iptv_service.dart';
import '../services/player_launcher.dart';

class PlayerScreen extends StatefulWidget {
  final Channel channel;
  final bool live;
  final List<Channel> playlist;

  const PlayerScreen({
    super.key,
    required this.channel,
    this.live = true,
    this.playlist = const <Channel>[],
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player;
  late final VideoController _controller;
  late Channel _current;

  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _bufferingSub;

  bool _showControls = true;
  bool _buffering = true;
  bool _locked = false;
  int _retryCount = 0;
  static const int _maxRetries = 5;
  Timer? _hideTimer;
  BoxFit _boxFit = BoxFit.contain;

  static const Map<String, String> _defaultHeaders = {
    'User-Agent': 'ExoPlayerLib/2.19.1 (Linux; Android 13) ExoPlayerDemo/2.19.1',
    'Connection': 'keep-alive',
  };

  @override
  void initState() {
    super.initState();
    _current = widget.channel;
    WakelockPlus.enable();
    _initPlayer();
    _openChannel(_current);
    _scheduleHideControls();
  }

  void _initPlayer() {
    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 32 * 1024 * 1024,
        vo: 'gpu',
      ),
    );

    if (_player.platform is NativePlayer) {
      final native = _player.platform as NativePlayer;
      native.setProperty('hwdec', 'auto-safe');
      native.setProperty(
        'stream-lavf-o',
        'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5',
      );
      native.setProperty('cache', 'yes');
      native.setProperty('demuxer-max-bytes', '33554432');
      native.setProperty('demuxer-readahead-secs', '10');
    }

    _controller = VideoController(_player);

    _bufferingSub = _player.stream.buffering.listen((isBuff) {
      if (mounted) setState(() => _buffering = isBuff);
    });

    _errorSub = _player.stream.error.listen((err) async {
      if (err.isEmpty || !mounted) return;
      if (_retryCount < _maxRetries) {
        _retryCount++;
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        await _player.open(
          Media(_current.url, httpHeaders: _defaultHeaders),
          play: true,
        );
      }
    });
  }

  Future<void> _openChannel(Channel ch) async {
    _retryCount = 0;
    setState(() {
      _current = ch;
      _buffering = true;
    });
    await _player.open(
      Media(ch.url, httpHeaders: _defaultHeaders),
      play: true,
    );
  }

  void _scheduleHideControls() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHideControls();
  }

  void _cycleFit() {
    setState(() {
      if (_boxFit == BoxFit.contain) {
        _boxFit = BoxFit.cover;
      } else if (_boxFit == BoxFit.cover) {
        _boxFit = BoxFit.fill;
      } else {
        _boxFit = BoxFit.contain;
      }
    });
  }

  Channel? _adjacentChannel(int delta) {
    if (widget.playlist.isEmpty) return null;
    final idx = widget.playlist.indexWhere((c) => c.id == _current.id);
    if (idx == -1) return null;
    final nextIdx = (idx + delta) % widget.playlist.length;
    return widget.playlist[nextIdx < 0 ? widget.playlist.length - 1 : nextIdx];
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _errorSub?.cancel();
    _bufferingSub?.cancel();
    WakelockPlus.disable();
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prevCh = _adjacentChannel(-1);
    final nextCh = _adjacentChannel(1);

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _locked
            ? () => setState(() => _showControls = !_showControls)
            : _toggleControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Video(
              controller: _controller,
              fit: _boxFit,
              controls: NoVideoControls,
            ),
            if (_buffering)
              const Center(
                child: CircularProgressIndicator(color: Color(0xFF42A5FF)),
              ),
            if (_locked && _showControls)
              Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton.tonalIcon(
                    onPressed: () => setState(() => _locked = false),
                    icon: const Icon(Icons.lock_open_rounded),
                    label: const Text('إلغاء القفل'),
                  ),
                ),
              ),
            if (!_locked && _showControls) ...[
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  color: Colors.black54,
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _current.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              _current.group,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Color(0xFF9BB2CC), fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'تغيير نسبة العرض',
                        onPressed: _cycleFit,
                        icon: const Icon(Icons.aspect_ratio_rounded, color: Colors.white),
                      ),
                      IconButton(
                        tooltip: 'قفل الشاشة',
                        onPressed: () => setState(() => _locked = true),
                        icon: const Icon(Icons.lock_rounded, color: Colors.white),
                      ),
                      TextButton.icon(
                        onPressed: () => launchInMxPlayer(_current.url, title: _current.name),
                        icon: const Icon(Icons.open_in_new_rounded, size: 16, color: Color(0xFF65D6A0)),
                        label: const Text('MX', style: TextStyle(color: Color(0xFF65D6A0))),
                      ),
                      TextButton.icon(
                        onPressed: () => launchInYtvPlayer(_current.url, title: _current.name),
                        icon: const Icon(Icons.live_tv_rounded, size: 16, color: Color(0xFF42A5FF)),
                        label: const Text('YTV', style: TextStyle(color: Color(0xFF42A5FF))),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                bottom: 18,
                left: 20,
                right: 20,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (prevCh != null)
                      IconButton.filledTonal(
                        onPressed: () => _openChannel(prevCh),
                        icon: const Icon(Icons.skip_previous_rounded),
                      ),
                    const SizedBox(width: 14),
                    IconButton.filled(
                      iconSize: 30,
                      onPressed: () => _player.playOrPause(),
                      icon: StreamBuilder<bool>(
                        stream: _player.stream.playing,
                        initialData: true,
                        builder: (_, snap) => Icon(
                          (snap.data ?? true) ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    if (nextCh != null)
                      IconButton.filledTonal(
                        onPressed: () => _openChannel(nextCh),
                        icon: const Icon(Icons.skip_next_rounded),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
