import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/iptv_service.dart';
import '../state/app_settings.dart';
import '../state/library_state.dart';

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
  late final AppSettings _cfg;
  final _fits = [BoxFit.contain, BoxFit.cover, BoxFit.fill, BoxFit.none];
  final _fitNames = ['احتواء', 'ملء الشاشة', 'تمديد', 'الحجم الأصلي'];
  final _subs = <StreamSubscription>[];
  List<String> _urls = [];
  int _fit = 0, _attempt = 0;
  late String _decoder;
  bool _buffering = true, _disposed = false, _historyAdded = false, _triedSoftware = false;
  String? _error, _note;

  @override
  void initState() {
    super.initState();
    _lib = context.read<LibraryState>();
    _cfg = context.read<AppSettings>();
    _fit = _cfg.fit;
    _decoder = _cfg.decoder;
    WakelockPlus.enable();
    _player = Player(configuration: PlayerConfiguration(bufferSize: _cfg.bufferMb * 1024 * 1024));
    _controller = VideoController(_player);
    _urls = _candidates(widget.channel.url);
    _subs.add(_player.stream.buffering.listen((b) { if (mounted) setState(() => _buffering = b); }));
    _subs.add(_player.stream.playing.listen((p) {
      if (p && mounted && (_error != null || _note != null)) setState(() { _error = null; _note = null; });
    }));
    _subs.add(_player.stream.error.listen(_onError));
    if (!widget.isLive) {
      _subs.add(_player.stream.position.listen((p) {
        if (p.inSeconds > 0 && p.inSeconds % 5 == 0) _lib.savePosition(widget.channel.id, p);
      }));
    }
    _start();
  }

  /// روابط Xtream المباشرة: جرّب .ts ثم .m3u8 (أو العكس) عند الفشل
  List<String> _candidates(String url) {
    final out = <String>[url];
    final m = RegExp(r'^(.*/live/[^/]+/[^/]+/\d+)\.(ts|m3u8)$').firstMatch(url);
    if (m != null) out.add('${m[1]}.${m[2] == 'ts' ? 'm3u8' : 'ts'}');
    return out;
  }

  Future<void> _applyOptions() async {
    final p = _player.platform as dynamic;
    Future<void> set(String k, String v) async { try { await p.setProperty(k, v); } catch (_) {} }
    await set('user-agent', 'VLC/3.0.20 LibVLC/3.0.20');
    await set('hwdec', AppSettings.hwdec(_decoder));
    await set('network-timeout', '20');
    await set('rtsp-transport', 'tcp');
    await set('demuxer-lavf-o', 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5');
  }

  Future<void> _start() async {
    await _applyOptions();
    await _openCurrent();
  }

  Future<void> _openCurrent() async {
    if (_disposed || !mounted) return;
    setState(() { _buffering = true; _error = null; });
    final resume = widget.isLive ? Duration.zero : _lib.resumePosition(widget.channel.id);
    try {
      await _player.open(Media(_urls[_attempt], start: resume > Duration.zero ? resume : null));
      if (!_historyAdded) { _historyAdded = true; _lib.addHistory(widget.channel); }
    } catch (e) {
      _onError('$e');
    }
  }

  void _onError(String e) {
    if (_disposed || !mounted || e.isEmpty) return;
    if (_attempt + 1 < _urls.length) {
      _attempt++;
      setState(() => _note = 'جارٍ تجربة رابط بديل ${_attempt + 1}/${_urls.length}');
      _openCurrent();
      return;
    }
    if (_decoder != 'sw' && !_triedSoftware) {
      _triedSoftware = true;
      _decoder = 'sw';
      setState(() => _note = 'جارٍ التجربة بفك التشفير البرمجي');
      _attempt = 0;
      _applyOptions().then((_) => _openCurrent());
      return;
    }
    setState(() { _buffering = false; _error = e; });
  }

  Future<void> _cycleDecoder() async {
    const order = ['auto', 'hw', 'sw'];
    _decoder = order[(order.indexOf(_decoder) + 1) % order.length];
    _attempt = 0; _triedSoftware = _decoder == 'sw';
    setState(() => _note = '${t('وضع فك التشفير')}: ${_decoderLabel()}');
    await _applyOptions();
    await _openCurrent();
  }

  String _decoderLabel() => _decoder == 'hw' ? t('عتاد (Hardware)')
      : _decoder == 'sw' ? t('برمجي (Software)') : t('تلقائي');

  @override
  void dispose() {
    _disposed = true;
    if (!widget.isLive) _lib.savePosition(widget.channel.id, _player.state.position);
    for (final s in _subs) { s.cancel(); }
    WakelockPlus.disable();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [
          Video(controller: _controller, fit: _fits[_fit], controls: NoVideoControls),
          if (_buffering && _error == null) const Center(child: CircularProgressIndicator()),
          if (_note != null && _error == null)
            Positioned(bottom: 24, left: 0, right: 0, child: Center(child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
              child: Text(_note!, style: const TextStyle(color: Colors.white, fontSize: 13))))),
          if (_error != null)
            Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
                const SizedBox(height: 8),
                Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 12),
                FilledButton(onPressed: () {
                  _attempt = 0; _triedSoftware = false;
                  _openCurrent();
                }, child: Text(t('إعادة المحاولة'))),
              ]))),
          Positioned(top: 16, left: 16, right: 16, child: Row(children: [
            Expanded(child: Text(widget.channel.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600))),
            IconButton(icon: const Icon(Icons.memory, color: Colors.white),
                tooltip: t('تبديل وضع فك التشفير'), onPressed: _cycleDecoder),
            IconButton(icon: const Icon(Icons.aspect_ratio, color: Colors.white),
                tooltip: t('تغيير نسبة العرض'),
                onPressed: () => setState(() {
                  _fit = (_fit + 1) % _fits.length;
                  _note = t(_fitNames[_fit]);
                })),
            IconButton(icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context)),
          ])),
        ]),
      );
}
