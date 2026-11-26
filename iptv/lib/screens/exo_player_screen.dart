import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/iptv_service.dart';
import '../services/parental_control.dart';
import '../state/app_settings.dart';
import '../state/library_state.dart';

/// المشغّل الداخلي 2: ExoPlayer (Media3) عبر حزمة video_player
class ExoPlayerScreen extends StatefulWidget {
  final Channel channel;
  final bool isLive;
  final List<Channel> playlist;
  const ExoPlayerScreen({super.key, required this.channel, this.isLive = true, this.playlist = const []});

  @override
  State<ExoPlayerScreen> createState() => _ExoPlayerScreenState();
}

class _ExoPlayerScreenState extends State<ExoPlayerScreen> {
  static const _fits = [BoxFit.contain, BoxFit.cover, BoxFit.fill];
  static const _fitNames = ['احتواء', 'ملء الشاشة', 'تمديد'];
  static const int _maxLiveRetries = 4;

  late final LibraryState _lib;
  late final AppSettings _cfg;
  final _focus = FocusNode();

  VideoPlayerController? _vc;
  late Channel _ch;
  int _index = 0, _fit = 0, _attempt = 0, _liveRetries = 0, _gen = 0;
  List<String> _urls = [];
  bool _overlay = true, _historyAdded = false, _disposed = false, _failing = false, _buffering = true;
  String? _error, _note, _osd;
  double _volume = 1, _dim = 0;
  double? _dragVal;
  int _lastSave = -1;
  Timer? _hideTimer, _osdTimer, _retryTimer;

  @override
  void initState() {
    super.initState();
    _lib = context.read<LibraryState>();
    _cfg = context.read<AppSettings>();
    _ch = widget.channel;
    final i = widget.playlist.indexWhere((c) => c.url == _ch.url);
    _index = i < 0 ? 0 : i;
    _fit = _cfg.fit.clamp(0, _fits.length - 1).toInt();
    _urls = _candidates(_ch.url);
    WakelockPlus.enable();
    _showOverlayBriefly();
    _open();
  }

  List<String> _candidates(String url) {
    final out = <String>[url];
    final m = RegExp(r'^(.*/live/[^/]+/[^/]+/\d+)\.(ts|m3u8)$').firstMatch(url);
    if (m != null) {
      out.add('${m[1]}.${m[2] == 'ts' ? 'm3u8' : 'ts'}');
      final pref = _cfg.liveFormat;
      if (pref != 'auto') {
        out.sort((a, b) => (b.endsWith('.$pref') ? 1 : 0).compareTo(a.endsWith('.$pref') ? 1 : 0));
      }
    }
    return out;
  }

  Future<void> _open() async {
    if (_disposed || !mounted) return;
    _retryTimer?.cancel();
    final gen = ++_gen;
    final old = _vc;
    old?.removeListener(_onTick);
    _failing = false;
    setState(() {
      _vc = null;
      _error = null;
      _buffering = true;
    });
    // ننتظر إزالة الودجت القديم من الشجرة قبل التخلص من المتحكم
    await WidgetsBinding.instance.endOfFrame;
    await old?.dispose();
    if (_disposed || gen != _gen) return;

    final url = _urls[_attempt];
    final c = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: kHttpHeaders,
      formatHint: url.toLowerCase().contains('.m3u8') ? VideoFormat.hls : null,
    );
    try {
      await c.initialize();
      if (_disposed || gen != _gen) {
        await c.dispose();
        return;
      }
      final resume = widget.isLive ? Duration.zero : _lib.resumePosition(_ch.id);
      if (resume > Duration.zero && resume < c.value.duration) await c.seekTo(resume);
      await c.setVolume(_volume);
      c.addListener(_onTick);
      await c.play();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _vc = c;
        _note = null;
      });
      if (!_historyAdded) {
        _historyAdded = true;
        _lib.addHistory(_ch);
      }
    } catch (e) {
      await c.dispose();
      if (gen == _gen) _onError('$e');
    }
  }

  void _onTick() {
    final c = _vc;
    if (c == null || _disposed || !mounted) return;
    final v = c.value;
    if (v.hasError && !_failing) {
      _failing = true;
      _onError(v.errorDescription ?? 'error');
      return;
    }
    if (!widget.isLive && v.isPlaying) {
      final s = v.position.inSeconds;
      if (s > 0 && s % 5 == 0 && s != _lastSave) {
        _lastSave = s;
        _lib.savePosition(_ch.id, v.position);
      }
    }
    if (v.isBuffering != _buffering || _overlay) {
      setState(() => _buffering = v.isBuffering);
    }
  }

  void _onError(String e) {
    if (_disposed || !mounted) return;
    if (_attempt + 1 < _urls.length) {
      _attempt++;
      setState(() => _note = 'جارٍ تجربة رابط بديل ${_attempt + 1}/${_urls.length}');
      _open();
      return;
    }
    if (widget.isLive && _liveRetries < _maxLiveRetries) {
      _liveRetries++;
      _attempt = 0;
      setState(() => _note = 'انقطع البث، إعادة المحاولة $_liveRetries/$_maxLiveRetries');
      _retryTimer = Timer(Duration(seconds: 2 * _liveRetries), _open);
      return;
    }
    setState(() {
      _error = 'تعذّر تشغيل هذا المحتوى بالمشغّل الداخلي 2. جرّب مشغّلًا آخر من الإعدادات.';
      _note = null;
      _buffering = false;
    });
  }

  void _switchTo(int i) {
    final pl = widget.playlist;
    if (i < 0 || i >= pl.length) return;
    if (context.read<ParentalControl>().isLocked(pl[i].group)) {
      setState(() => _note = '🔒 ${pl[i].group}');
      return;
    }
    final c = _vc;
    if (!widget.isLive && c != null) _lib.savePosition(_ch.id, c.value.position);
    _index = i;
    _ch = pl[i];
    _urls = _candidates(_ch.url);
    _attempt = 0;
    _liveRetries = 0;
    _historyAdded = false;
    _lastSave = -1;
    _showOverlayBriefly();
    _open();
  }

  // ---------------- التحكم ----------------
  void _showOverlayBriefly() {
    _hideTimer?.cancel();
    if (mounted) setState(() => _overlay = true);
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _error == null) setState(() => _overlay = false);
    });
  }

  void _toggleOverlay() {
    if (_overlay) {
      _hideTimer?.cancel();
      setState(() => _overlay = false);
    } else {
      _showOverlayBriefly();
    }
  }

  void _flash(String s) {
    _osdTimer?.cancel();
    if (mounted) setState(() => _osd = s);
    _osdTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _osd = null);
    });
  }

  void _togglePlay() {
    final c = _vc;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
    _showOverlayBriefly();
  }

  void _seekBy(int sec) {
    final c = _vc;
    if (c == null || widget.isLive) return;
    var target = c.value.position + Duration(seconds: sec);
    if (target < Duration.zero) target = Duration.zero;
    if (target > c.value.duration) target = c.value.duration;
    c.seekTo(target);
    _flash(sec > 0 ? '⏩ +$sec' : '⏪ $sec');
  }

  void _setVolume(double v) {
    _volume = v.clamp(0.0, 1.0).toDouble();
    _vc?.setVolume(_volume);
    if (mounted) setState(() {});
  }

  void _setDim(double d) {
    _dim = d.clamp(0.0, 0.8).toDouble();
    if (mounted) setState(() {});
  }

  void _changeVolume(double delta) {
    _setVolume(_volume + delta);
    _flash('🔊 ${(_volume * 100).round()}%');
  }

  void _changeBrightness(double delta) {
    _setDim(_dim - delta);
    _flash('🔆 ${((1 - _dim) * 100).round()}%');
  }

  Future<void> _levelSheet({required bool volume}) async {
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0D1726),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final value = volume ? _volume : 1 - _dim;
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Icon(volume ? Icons.volume_up_rounded : Icons.brightness_6_rounded, size: 20),
                const SizedBox(width: 10),
                Text(t(volume ? 'مستوى الصوت' : 'سطوع الشاشة'),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('${(value * 100).round()}%'),
              ]),
              Slider(
                value: value.clamp(volume ? 0.0 : 0.2, 1.0).toDouble(),
                min: volume ? 0 : 0.2,
                max: 1,
                onChanged: (x) {
                  if (volume) {
                    _setVolume(x);
                  } else {
                    _setDim(1 - x);
                  }
                  setS(() {});
                },
              ),
            ]),
          );
        },
      ),
    );
    if (mounted) _showOverlayBriefly();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final isDown = e is KeyDownEvent;
    if (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      if (isDown) {
        if (_overlay) {
          _togglePlay();
        } else {
          _showOverlayBriefly();
        }
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPlayPause || k == LogicalKeyboardKey.space) {
      if (isDown) _togglePlay();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.mediaRewind) {
      if (widget.isLive) {
        _showOverlayBriefly();
      } else {
        _seekBy(-10);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.mediaFastForward) {
      if (widget.isLive) {
        _showOverlayBriefly();
      } else {
        _seekBy(10);
      }
      return KeyEventResult.handled;
    }
    if (isDown && (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.channelUp ||
        k == LogicalKeyboardKey.mediaTrackPrevious)) {
      _switchTo(_index - 1);
      return KeyEventResult.handled;
    }
    if (isDown && (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.channelDown ||
        k == LogicalKeyboardKey.mediaTrackNext)) {
      _switchTo(_index + 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    _hideTimer?.cancel();
    _osdTimer?.cancel();
    _retryTimer?.cancel();
    final c = _vc;
    if (c != null) {
      if (!widget.isLive) _lib.savePosition(_ch.id, c.value.position);
      c.removeListener(_onTick);
      c.dispose();
    }
    _focus.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // ---------------- الواجهة ----------------
  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}' : '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
  }

  Widget _btn(IconData i, String tip, VoidCallback f, {double size = 24, Color color = Colors.white}) => IconButton(
        icon: Icon(i, color: color, size: size),
        tooltip: tip,
        onPressed: () {
          f();
          _showOverlayBriefly();
        },
      );

  Widget _video(VideoPlayerController? c) {
    if (c == null || !c.value.isInitialized) return const SizedBox.shrink();
    final size = c.value.size;
    final w = size.width <= 0 ? 16.0 : size.width;
    final h = size.height <= 0 ? 9.0 : size.height;
    return SizedBox.expand(
      child: FittedBox(
        fit: _fits[_fit],
        clipBehavior: Clip.hardEdge,
        child: SizedBox(width: w, height: h, child: VideoPlayer(c)),
      ),
    );
  }

  Widget _chip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: const TextStyle(fontSize: 13)),
      );

  Widget _topBar() {
    final fav = _lib.isFavorite(_ch.id);
    return Positioned(
      top: 0, left: 0, right: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 4, 8, 16),
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Color(0xCC000000), Colors.transparent]),
        ),
        child: SafeArea(
          bottom: false,
          child: Row(children: [
            _btn(Icons.arrow_back_rounded, t('رجوع'), () => Navigator.maybePop(context)),
            Expanded(
              child: Text(_ch.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            _btn(_volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded, t('مستوى الصوت'),
                () => _levelSheet(volume: true)),
            _btn(Icons.brightness_6_rounded, t('سطوع الشاشة'), () => _levelSheet(volume: false),
                color: _dim > 0 ? const Color(0xFFFFD84D) : Colors.white),
            _btn(Icons.aspect_ratio_rounded, t(_fitNames[_fit]), () {
              _fit = (_fit + 1) % _fits.length;
              _flash(t(_fitNames[_fit]));
              setState(() {});
            }),
            _btn(fav ? Icons.star : Icons.star_border, t('المفضلة'), () {
              _lib.toggleFavorite(_ch);
              setState(() {});
            }, color: fav ? const Color(0xFFFFD84D) : Colors.white),
          ]),
        ),
      ),
    );
  }

  Widget _centerControls(VideoPlayerController c) {
    final playing = c.value.isPlaying;
    final multi = widget.playlist.length > 1;
    return Center(
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (multi) _btn(Icons.skip_previous_rounded, t('السابق'), () => _switchTo(_index - 1), size: 40),
        const SizedBox(width: 12),
        _btn(playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
            t(playing ? 'إيقاف مؤقت' : 'تشغيل'), _togglePlay, size: 62),
        const SizedBox(width: 12),
        if (multi) _btn(Icons.skip_next_rounded, t('التالي'), () => _switchTo(_index + 1), size: 40),
      ]),
    );
  }

  Widget _bottomBar(VideoPlayerController? c) {
    final pos = c?.value.position ?? Duration.zero;
    final dur = c?.value.duration ?? Duration.zero;
    final max = dur.inMilliseconds.toDouble();
    final shown = _dragVal ?? pos.inMilliseconds.toDouble();
    return Positioned(
      bottom: 0, left: 0, right: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 18, 14, 10),
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter,
              colors: [Color(0xCC000000), Colors.transparent]),
        ),
        child: SafeArea(
          top: false,
          child: widget.isLive
              ? Row(children: [
                  const Icon(Icons.circle, size: 10, color: Colors.redAccent),
                  const SizedBox(width: 6),
                  Text(t('مباشر'), style: const TextStyle(fontSize: 12)),
                  const Spacer(),
                  if (widget.playlist.isNotEmpty)
                    Text('${_index + 1}/${widget.playlist.length}', style: const TextStyle(fontSize: 12)),
                ])
              : Row(children: [
                  Text(_fmt(Duration(milliseconds: shown.round())), style: const TextStyle(fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: shown.clamp(0.0, max > 0 ? max : 1.0).toDouble(),
                      max: max > 0 ? max : 1.0,
                      onChanged: max > 0 ? (x) => setState(() => _dragVal = x) : null,
                      onChangeEnd: (x) {
                        c?.seekTo(Duration(milliseconds: x.round()));
                        setState(() => _dragVal = null);
                      },
                    ),
                  ),
                  Text(_fmt(dur), style: const TextStyle(fontSize: 12)),
                ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _vc;
    final ready = c != null && c.value.isInitialized;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: LayoutBuilder(
          builder: (context, box) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleOverlay,
            onDoubleTap: _togglePlay,
            onVerticalDragUpdate: (d) {
              if (d.localPosition.dx > box.maxWidth / 2) {
                _changeVolume(-d.delta.dy / 300);
              } else {
                _changeBrightness(-d.delta.dy / 300);
              }
            },
            child: Stack(fit: StackFit.expand, children: [
              Center(child: _video(c)),
              if (_dim > 0)
                IgnorePointer(child: ColoredBox(color: Colors.black.withAlpha((_dim * 255).round()))),
              if ((_buffering || !ready) && _error == null)
                const IgnorePointer(child: Center(child: CircularProgressIndicator())),
              if (_note != null)
                Positioned(top: 72, left: 0, right: 0, child: Center(child: _chip(t(_note!)))),
              if (_osd != null) Center(child: _chip(_osd!)),
              if (_error != null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.error_outline_rounded, size: 44, color: Colors.redAccent),
                      const SizedBox(height: 10),
                      Text(t(_error!), textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        onPressed: () {
                          _attempt = 0;
                          _liveRetries = 0;
                          _open();
                        },
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(t('إعادة المحاولة')),
                      ),
                    ]),
                  ),
                ),
              if (_overlay) ...[
                _topBar(),
                if (ready) _centerControls(c),
                _bottomBar(c),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
