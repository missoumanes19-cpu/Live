import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/iptv_service.dart';
import '../state/library_state.dart';

// main(): MediaKit.ensureInitialized();  (قبل runApp)
class PlayerScreen extends StatefulWidget {
  final Channel channel;
  final bool isLive;
  const PlayerScreen({super.key, required this.channel, this.isLive = true});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player;
  late final VideoController _controller;
  late final LibraryState _lib;
  final _fits = [BoxFit.contain, BoxFit.cover, BoxFit.fill, BoxFit.none];
  final _fitNames = ['احتواء', 'ملء الشاشة', 'تمديد', 'الحجم الأصلي'];
  int _fit = 0;
  bool _buffering = true;
  String? _error;
  final _subs = <dynamic>[];

  @override
  void initState() {
    super.initState();
    _lib = context.read<LibraryState>();
    WakelockPlus.enable();
    _player = Player(configuration: const PlayerConfiguration(bufferSize: 32 * 1024 * 1024));
    _controller = VideoController(_player,
        configuration: const VideoControllerConfiguration(
            enableHardwareAcceleration: true)); // MediaCodec على أندرويد
    // مهم لـ RTSP: استخدام TCP
    (_player.platform as dynamic).setProperty('rtsp-transport', 'tcp');
    _subs.add(_player.stream.buffering.listen((b) => setState(() => _buffering = b)));
    _subs.add(_player.stream.error.listen((e) => setState(() => _error = e)));
    _open();
  }

  Future<void> _open() async {
    final resume = widget.isLive ? Duration.zero : _lib.resumePosition(widget.channel.id);
    await _player.open(Media(widget.channel.url, start: resume));
    _lib.addHistory(widget.channel);
    if (!widget.isLive) {
      _subs.add(_player.stream.position.listen((p) {
        if (p.inSeconds % 5 == 0) _lib.savePosition(widget.channel.id, p);
      }));
    }
  }

  @override
  void dispose() {
    if (!widget.isLive) _lib.savePosition(widget.channel.id, _player.state.position);
    for (final s in _subs) { s.cancel(); }
    WakelockPlus.disable();
    _player.dispose(); // تحرير الذاكرة والمفكّكات
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          Video(controller: _controller, fit: _fits[_fit], controls: NoVideoControls),
          if (_buffering && _error == null)
            const Center(child: CircularProgressIndicator()),
          if (_error != null)
            Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              Text(_error!, style: const TextStyle(color: Colors.white)),
              TextButton(onPressed: () { setState(() => _error = null); _open(); },
                  child: const Text('إعادة المحاولة')),
            ])),
          Positioned(top: 24, right: 12, child: Row(children: [
            IconButton(icon: const Icon(Icons.aspect_ratio, color: Colors.white),
                tooltip: _fitNames[_fit],
                onPressed: () => setState(() => _fit = (_fit + 1) % _fits.length)),
            IconButton(icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context)),
          ])),
        ]),
      );
}
