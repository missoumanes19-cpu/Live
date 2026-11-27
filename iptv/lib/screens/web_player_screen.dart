import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../services/iptv_service.dart';
import '../services/local_proxy.dart';
import '../services/parental_control.dart';
import '../state/app_settings.dart';
import '../state/library_state.dart';

/// المشغّل الداخلي 3: Video.js داخل WebView، والوسائط تمرّ عبر وسيط محلي (راجع local_proxy.dart)
class WebPlayerScreen extends StatefulWidget {
  final Channel channel;
  final bool isLive;
  final List<Channel> playlist;
  const WebPlayerScreen({super.key, required this.channel, this.isLive = true, this.playlist = const []});

  @override
  State<WebPlayerScreen> createState() => _WebPlayerScreenState();
}

class _WebPlayerScreenState extends State<WebPlayerScreen> {
  static const int _maxLiveRetries = 4;

  late final LibraryState _lib;
  late final WebViewController _wc;
  late Channel _ch;
  int _index = 0, _attempt = 0, _liveRetries = 0;
  List<String> _urls = [];
  bool _overlay = true, _historyAdded = false, _disposed = false, _loading = true;
  String? _error, _note;
  double _dim = 0;
  Timer? _hideTimer, _retryTimer;

  @override
  void initState() {
    super.initState();
    _lib = context.read<LibraryState>();
    _ch = widget.channel;
    final i = widget.playlist.indexWhere((c) => c.url == _ch.url);
    _index = i < 0 ? 0 : i;
    _urls = _candidates(_ch.url);
    WakelockPlus.enable();

    _wc = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel('Flutter', onMessageReceived: (m) => _onMsg(m.message))
      ..setNavigationDelegate(NavigationDelegate(
        onWebResourceError: (e) {
          if (e.isForMainFrame ?? true) _onError(e.description);
        },
      ));
    final platform = _wc.platform;
    if (platform is AndroidWebViewController) {
      platform.setMediaPlaybackRequiresUserGesture(false);
    }
    _showOverlayBriefly();
    _load();
  }

  /// Video.js يشغّل HLS وMP4 فقط، لذا نفضّل m3u8 لقنوات Xtream المباشرة
  List<String> _candidates(String url) {
    final out = <String>[url];
    final m = RegExp(r'^(.*/live/[^/]+/[^/]+/\d+)\.(ts|m3u8)$').firstMatch(url);
    if (m != null) {
      out.add('${m[1]}.${m[2] == 'ts' ? 'm3u8' : 'ts'}');
      out.sort((a, b) => (b.endsWith('.m3u8') ? 1 : 0).compareTo(a.endsWith('.m3u8') ? 1 : 0));
    }
    return out;
  }

  Future<void> _load() async {
    if (_disposed || !mounted) return;
    _retryTimer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final proxy = LocalMediaProxy.instance;
      final port = await proxy.start();
      final resume = widget.isLive ? Duration.zero : _lib.resumePosition(_ch.id);
      await _wc.loadRequest(Uri.parse(
          proxy.playerUrl(port, media: _urls[_attempt], live: widget.isLive, start: resume.inSeconds)));
    } catch (e) {
      _onError('$e');
    }
  }

  void _onMsg(String raw) {
    if (_disposed || !mounted) return;
    Map<String, dynamic> m;
    try {
      m = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['t']) {
      case 'playing':
        _liveRetries = 0;
        setState(() {
          _loading = false;
          _note = null;
        });
        if (!_historyAdded) {
          _historyAdded = true;
          _lib.addHistory(_ch);
        }
        break;
      case 'waiting':
        setState(() => _loading = true);
        break;
      case 'time':
        final p = (m['p'] as num?)?.toDouble() ?? 0;
        if (!widget.isLive && p > 0) _lib.savePosition(_ch.id, Duration(seconds: p.round()));
        break;
      case 'tap':
        _showOverlayBriefly();
        break;
      case 'error':
        if (m['c'] == -1) {
          setState(() {
            _loading = false;
            _error = 'يحتاج المشغّل الداخلي 3 (Video.js) إلى اتصال بالإنترنت لتحميله.';
          });
        } else {
          _onError('${m['m']}');
        }
        break;
    }
  }

  void _onError(String e) {
    if (_disposed || !mounted) return;
    if (_attempt + 1 < _urls.length) {
      _attempt++;
      setState(() => _note = 'جارٍ تجربة رابط بديل ${_attempt + 1}/${_urls.length}');
      _load();
      return;
    }
    if (widget.isLive && _liveRetries < _maxLiveRetries) {
      _liveRetries++;
      _attempt = 0;
      setState(() => _note = 'انقطع البث، إعادة المحاولة $_liveRetries/$_maxLiveRetries');
      _retryTimer = Timer(Duration(seconds: 2 * _liveRetries), _load);
      return;
    }
    setState(() {
      _loading = false;
      _note = null;
      _error = 'تعذّر تشغيل هذا المحتوى بالمشغّل الداخلي 3 (يدعم HLS وMP4 فقط). جرّب مشغّلًا آخر من الإعدادات.';
    });
  }

  void _switchTo(int i) {
    final pl = widget.playlist;
    if (i < 0 || i >= pl.length) return;
    if (context.read<ParentalControl>().isLocked(pl[i].group)) {
      setState(() => _note = '🔒 ${pl[i].group}');
      return;
    }
    _index = i;
    _ch = pl[i];
    _urls = _candidates(_ch.url);
    _attempt = 0;
    _liveRetries = 0;
    _historyAdded = false;
    _showOverlayBriefly();
    _load();
  }

  void _showOverlayBriefly() {
    _hideTimer?.cancel();
    if (mounted) setState(() => _overlay = true);
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _error == null) setState(() => _overlay = false);
    });
  }

  Future<void> _brightnessSheet() async {
    _hideTimer?.cancel();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0D1726),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Icon(Icons.brightness_6_rounded, size: 20),
              const SizedBox(width: 10),
              Text(t('سطوع الشاشة'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
              const Spacer(),
              Text('${((1 - _dim) * 100).round()}%'),
            ]),
            Slider(
              value: (1 - _dim).clamp(0.2, 1.0).toDouble(),
              min: 0.2,
              max: 1,
              onChanged: (x) {
                setState(() => _dim = (1 - x).clamp(0.0, 0.8).toDouble());
                setS(() {});
              },
            ),
          ]),
        ),
      ),
    );
    if (mounted) _showOverlayBriefly();
  }

  @override
  void dispose() {
    _disposed = true;
    _hideTimer?.cancel();
    _retryTimer?.cancel();
    WakelockPlus.disable();
    super.dispose();
  }

  Widget _btn(IconData i, String tip, VoidCallback f, {Color color = Colors.white}) => IconButton(
        icon: Icon(i, color: color, size: 24),
        tooltip: tip,
        onPressed: () {
          f();
          _showOverlayBriefly();
        },
      );

  Widget _chip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: const TextStyle(fontSize: 13)),
      );

  Widget _topBar() {
    final fav = _lib.isFavorite(_ch.id);
    final multi = widget.playlist.length > 1;
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
            if (multi) _btn(Icons.skip_previous_rounded, t('السابق'), () => _switchTo(_index - 1)),
            if (multi) _btn(Icons.skip_next_rounded, t('التالي'), () => _switchTo(_index + 1)),
            _btn(Icons.brightness_6_rounded, t('سطوع الشاشة'), _brightnessSheet,
                color: _dim > 0 ? const Color(0xFFFFD84D) : Colors.white),
            _btn(fav ? Icons.star : Icons.star_border, t('المفضلة'), () {
              _lib.toggleFavorite(_ch);
              setState(() {});
            }, color: fav ? const Color(0xFFFFD84D) : Colors.white),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(fit: StackFit.expand, children: [
        WebViewWidget(controller: _wc),
        if (_dim > 0) IgnorePointer(child: ColoredBox(color: Colors.black.withAlpha((_dim * 255).round()))),
        if (_loading && _error == null) const IgnorePointer(child: Center(child: CircularProgressIndicator())),
        if (_note != null) Positioned(top: 72, left: 0, right: 0, child: Center(child: _chip(t(_note!)))),
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
                    _load();
                  },
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(t('إعادة المحاولة')),
                ),
              ]),
            ),
          ),
        if (_overlay) _topBar(),
      ]),
    );
  }
}
