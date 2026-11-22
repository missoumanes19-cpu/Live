import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/epg_service.dart';
import '../services/iptv_service.dart';
import '../services/parental_control.dart';
import '../state/app_settings.dart';
import '../state/library_state.dart';

class PlayerScreen extends StatefulWidget {
  final Channel channel;
  final bool isLive;
  final List<Channel> playlist; // لتبديل القنوات بالريموت
  const PlayerScreen({super.key, required this.channel, this.isLive = true, this.playlist = const []});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player;
  late final VideoController _controller;
  late final LibraryState _lib;
  late final AppSettings _cfg;
  final _focus = FocusNode();
  final _fits = [BoxFit.contain, BoxFit.cover, BoxFit.fill, BoxFit.none];
  final _fitNames = ['احتواء', 'ملء الشاشة', 'تمديد', 'الحجم الأصلي'];
  final _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  final _subs = <StreamSubscription>[];
  late Channel _ch;
  Channel? _last;
  int _index = 0, _fit = 0, _attempt = 0, _sleepMin = 0, _lastSec = -1;
  List<String> _urls = [];
  late String _decoder;
  bool _buffering = true, _disposed = false, _historyAdded = false, _triedSoftware = false, _overlay = true;
  bool _playing = true, _drag = false, _showList = false;
  String? _error, _note, _osd;
  String _numBuf = '';
  Duration _pos = Duration.zero, _dur = Duration.zero;
  double _dragVal = 0, _volume = 100, _rate = 1.0, _dtX = 0;
  int? _vw, _vh;
  ScrollController? _listCtrl;
  Timer? _hideTimer, _numTimer, _sleepTimer, _osdTimer;

  @override
  void initState() {
    super.initState();
    _lib = context.read<LibraryState>();
    _cfg = context.read<AppSettings>();
    _ch = widget.channel;
    final i = widget.playlist.indexWhere((c) => c.url == _ch.url);
    _index = i < 0 ? 0 : i;
    _fit = _cfg.fit;
    _decoder = _cfg.decoder;
    WakelockPlus.enable();
    _player = Player(configuration: PlayerConfiguration(bufferSize: _cfg.bufferMb * 1024 * 1024));
    _controller = VideoController(_player);
    _urls = _candidates(_ch.url);
    _subs.add(_player.stream.buffering.listen((b) { if (mounted) setState(() => _buffering = b); }));
    _subs.add(_player.stream.playing.listen((p) {
      if (!mounted) return;
      setState(() {
        _playing = p;
        if (p && (_error != null || _note != null)) { _error = null; _note = null; }
      });
    }));
    _subs.add(_player.stream.error.listen(_onError));
    _subs.add(_player.stream.duration.listen((d) { _dur = d; }));
    _subs.add(_player.stream.width.listen((w) { if (mounted && w != _vw) setState(() => _vw = w); }));
    _subs.add(_player.stream.height.listen((h) { if (mounted && h != _vh) setState(() => _vh = h); }));
    _subs.add(_player.stream.position.listen((p) {
      _pos = p;
      if (!widget.isLive) {
        if (p.inSeconds > 0 && p.inSeconds % 5 == 0) _lib.savePosition(_ch.id, p);
        if (mounted && _overlay && !_drag && p.inSeconds != _lastSec) {
          _lastSec = p.inSeconds;
          setState(() {});
        }
      }
    }));
    _showOverlayBriefly();
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
    await set('tls-verify', 'no');
    await set('cache', 'yes');
    await set('cache-secs', widget.isLive ? '20' : '60');
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
    final resume = widget.isLive ? Duration.zero : _lib.resumePosition(_ch.id);
    try {
      await _player.open(Media(_urls[_attempt], start: resume > Duration.zero ? resume : null));
      await _player.setRate(_rate);
      if (!_historyAdded) { _historyAdded = true; _lib.addHistory(_ch); }
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

  // ---------- تبديل القنوات ----------
  void _step(int dir) {
    final pl = widget.playlist;
    if (pl.length < 2) return;
    final pc = context.read<ParentalControl>();
    var i = _index;
    for (var n = 0; n < pl.length; n++) {
      i = (i + dir + pl.length) % pl.length;
      if (!pc.isLocked(pl[i].group)) { _switchTo(i); return; }
    }
  }

  void _switchTo(int i) {
    final pl = widget.playlist;
    if (i < 0 || i >= pl.length) return;
    if (context.read<ParentalControl>().isLocked(pl[i].group)) {
      setState(() => _note = '🔒 ${pl[i].group}');
      return;
    }
    _last = _ch; _index = i; _ch = pl[i];
    _urls = _candidates(_ch.url); _attempt = 0; _triedSoftware = false;
    _decoder = _cfg.decoder; _historyAdded = false;
    _vw = null; _vh = null;
    _showOverlayBriefly();
    _applyOptions().then((_) => _openCurrent());
  }

  void _backToLast() {
    final l = _last;
    if (l == null) return;
    final i = widget.playlist.indexWhere((c) => c.url == l.url);
    if (i >= 0) _switchTo(i);
  }

  void _digit(String d) {
    _numBuf = _numBuf.length >= 4 ? d : _numBuf + d;
    setState(() {});
    _numTimer?.cancel();
    _numTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      final n = int.tryParse(_numBuf) ?? 0;
      setState(() => _numBuf = '');
      if (n >= 1 && n <= widget.playlist.length) _switchTo(n - 1);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final live = widget.isLive;
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.channelUp ||
        k == LogicalKeyboardKey.mediaTrackNext) {
      if (live) { _step(1); } else { _showOverlayBriefly(); }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.channelDown ||
        k == LogicalKeyboardKey.mediaTrackPrevious) {
      if (live) { _step(-1); } else { _showOverlayBriefly(); }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      if (live) { _openList(); } else { _seekBy(-10); }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      if (live) { _showOverlayBriefly(); } else { _seekBy(10); }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPlayPause) { _player.playOrPause(); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter) {
      if (!live) { _player.playOrPause(); _showOverlayBriefly(); }
      else if (_overlay) { _menu(); }
      else { _showOverlayBriefly(); }
      return KeyEventResult.handled;
    }
    final label = k.keyLabel;
    if (live && label.length == 1 && '0123456789'.contains(label)) {
      _digit(label);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---------- أدوات التحكم ----------
  void _flash(String s) {
    _osdTimer?.cancel();
    if (mounted) setState(() => _osd = s);
    _osdTimer = Timer(const Duration(milliseconds: 1200), () { if (mounted) setState(() => _osd = null); });
  }

  void _seekBy(int sec) {
    var target = _player.state.position + Duration(seconds: sec);
    if (target < Duration.zero) target = Duration.zero;
    _player.seek(target);
    _flash(sec < 0 ? '⏪ ${-sec}s' : '${sec}s ⏩');
    _showOverlayBriefly();
  }

  void _changeVolume(double delta) {
    _volume = (_volume + delta).clamp(0.0, 100.0).toDouble();
    _player.setVolume(_volume);
    _flash('🔊 ${_volume.round()}%');
  }

  void _doubleTap(double width) {
    if (widget.isLive) { _player.playOrPause(); return; }
    _seekBy(_dtX < width / 2 ? -10 : 10);
  }

  void _cycleRate() {
    final i = _rates.indexOf(_rate);
    _rate = _rates[(i + 1) % _rates.length];
    _player.setRate(_rate);
    _flash('${_rate}x');
  }

  void _cycleFit() {
    setState(() => _fit = (_fit + 1) % _fits.length);
    _flash(t(_fitNames[_fit]));
  }

  void _openList() {
    if (widget.playlist.length < 2) { _showOverlayBriefly(); return; }
    _listCtrl?.dispose();
    _listCtrl = ScrollController(initialScrollOffset: (_index * 44.0 - 120).clamp(0.0, double.infinity).toDouble());
    setState(() => _showList = true);
    _hideTimer?.cancel();
  }

  // ---------- الواجهة ----------
  void _showOverlayBriefly() {
    _hideTimer?.cancel();
    if (mounted) setState(() => _overlay = true);
    _hideTimer = Timer(const Duration(seconds: 5), () { if (mounted && !_drag) setState(() => _overlay = false); });
  }

  void _toggleOverlay() {
    if (_showList) { setState(() => _showList = false); return; }
    if (_overlay) { _hideTimer?.cancel(); setState(() => _overlay = false); } else { _showOverlayBriefly(); }
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

  void _cycleSleep() {
    const opts = [0, 15, 30, 60, 90];
    _sleepMin = opts[(opts.indexOf(_sleepMin) + 1) % opts.length];
    _sleepTimer?.cancel();
    if (_sleepMin > 0) {
      _sleepTimer = Timer(Duration(minutes: _sleepMin), () { if (mounted) Navigator.pop(context); });
    }
    setState(() => _note = _sleepMin == 0 ? t('مؤقّت النوم') : '${t('مؤقّت النوم')}: $_sleepMin');
  }

  String _trackName(String id, String? title, String? lang) {
    if (id == 'auto') return t('تلقائي');
    if (id == 'no') return t('إيقاف');
    final parts = [if (title != null && title.isNotEmpty) title, if (lang != null && lang.isNotEmpty) lang];
    return parts.isEmpty ? '#$id' : parts.join(' • ');
  }

  void _tracksSheet() {
    final tr = _player.state.tracks;
    final curA = _player.state.track.audio.id, curS = _player.state.track.subtitle.id;
    showModalBottomSheet(context: context, backgroundColor: const Color(0xFF101A2A), isScrollControlled: true,
      builder: (c) => SafeArea(child: ListView(shrinkWrap: true, children: [
        Padding(padding: const EdgeInsets.all(14),
          child: Text(t('الصوت'), style: const TextStyle(fontWeight: FontWeight.bold))),
        for (final a in tr.audio) ListTile(dense: true,
          title: Text(_trackName(a.id, a.title, a.language)),
          trailing: a.id == curA ? const Icon(Icons.check) : null,
          onTap: () { _player.setAudioTrack(a); Navigator.pop(c); }),
        Padding(padding: const EdgeInsets.all(14),
          child: Text(t('الترجمة'), style: const TextStyle(fontWeight: FontWeight.bold))),
        for (final s in tr.subtitle) ListTile(dense: true,
          title: Text(_trackName(s.id, s.title, s.language)),
          trailing: s.id == curS ? const Icon(Icons.check) : null,
          onTap: () { _player.setSubtitleTrack(s); Navigator.pop(c); }),
      ]))).then((_) => _focus.requestFocus());
  }

  void _menu() {
    final fav = _lib.isFavorite(_ch.id);
    showModalBottomSheet(context: context, backgroundColor: const Color(0xFF101A2A),
      builder: (c) => SafeArea(child: ListView(shrinkWrap: true, children: [
        ListTile(leading: Icon(fav ? Icons.star : Icons.star_border),
          title: Text(fav ? t('أزيلت من المفضلة') : t('أضيفت إلى المفضلة')),
          onTap: () { _lib.toggleFavorite(_ch); Navigator.pop(c); }),
        if (widget.isLive && widget.playlist.length > 1) ListTile(leading: const Icon(Icons.format_list_numbered),
          title: Text(t('قائمة القنوات')), onTap: () { Navigator.pop(c); _openList(); }),
        ListTile(leading: const Icon(Icons.subtitles), title: Text(t('الصوت والترجمة')),
          onTap: () { Navigator.pop(c); _tracksSheet(); }),
        ListTile(leading: const Icon(Icons.memory),
          title: Text('${t('وضع فك التشفير')}: ${_decoderLabel()}'),
          onTap: () { Navigator.pop(c); _cycleDecoder(); }),
        ListTile(leading: const Icon(Icons.aspect_ratio),
          title: Text('${t('نسبة العرض')}: ${t(_fitNames[_fit])}'),
          onTap: () { Navigator.pop(c); _cycleFit(); }),
        ListTile(leading: const Icon(Icons.bedtime),
          title: Text(_sleepMin == 0 ? t('مؤقّت النوم') : '${t('مؤقّت النوم')}: $_sleepMin'),
          onTap: () { Navigator.pop(c); _cycleSleep(); }),
      ]))).then((_) => _focus.requestFocus());
  }

  String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes.remainder(60), s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(2, '0'), ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  String? get _quality {
    final h = _vh;
    if (h == null || h <= 0) return null;
    final label = h >= 2000 ? '4K' : h >= 1000 ? 'FHD' : h >= 700 ? 'HD' : 'SD';
    return '$label ${_vw ?? ''}x$h';
  }

  @override
  void dispose() {
    _disposed = true;
    _hideTimer?.cancel(); _numTimer?.cancel(); _sleepTimer?.cancel(); _osdTimer?.cancel();
    _focus.dispose();
    _listCtrl?.dispose();
    if (!widget.isLive) _lib.savePosition(_ch.id, _player.state.position);
    for (final s in _subs) { s.cancel(); }
    WakelockPlus.disable();
    _player.dispose();
    super.dispose();
  }

  Widget _btn(IconData i, String tip, VoidCallback f, {double size = 26, Color color = Colors.white}) =>
      IconButton(icon: Icon(i, color: color, size: size), tooltip: tip,
        onPressed: () { f(); if (!_showList) _showOverlayBriefly(); });

  Widget _chip(String s) => Container(
    margin: const EdgeInsets.only(left: 6, right: 6),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(6)),
    child: Text(s, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)));

  Widget _topBar(bool fav) => Positioned(top: 0, left: 0, right: 0, child: Container(
    padding: const EdgeInsets.fromLTRB(16, 8, 8, 22),
    decoration: const BoxDecoration(gradient: LinearGradient(
      begin: Alignment.topCenter, end: Alignment.bottomCenter,
      colors: [Colors.black87, Colors.transparent])),
    child: Row(children: [
      if (widget.isLive && widget.playlist.length > 1) Container(
        margin: const EdgeInsetsDirectional.only(end: 10),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(color: const Color(0xFFFF8A00), borderRadius: BorderRadius.circular(8)),
        child: Text('${_index + 1}', style: const TextStyle(fontWeight: FontWeight.bold))),
      Expanded(child: Text(_ch.name, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600))),
      if (_quality != null) _chip(_quality!),
      if (widget.isLive) _chip('LIVE'),
      _btn(fav ? Icons.star : Icons.star_border, t('المفضلة'), () => _lib.toggleFavorite(_ch), size: 22),
      _btn(Icons.close, 'X', () => Navigator.pop(context), size: 22),
    ])));

  Widget _bottomBar(Program? now, Program? next) {
    final live = widget.isLive;
    final total = _dur.inMilliseconds.toDouble();
    final max = total <= 0 ? 1.0 : total;
    final cur = (_drag ? _dragVal : _pos.inMilliseconds.toDouble()).clamp(0.0, max).toDouble();
    return Positioned(bottom: 0, left: 0, right: 0, child: Container(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      decoration: const BoxDecoration(gradient: LinearGradient(
        begin: Alignment.bottomCenter, end: Alignment.topCenter,
        colors: [Colors.black87, Colors.transparent])),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (live && now != null) Padding(padding: const EdgeInsets.only(bottom: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${_hm(now.start)} – ${_hm(now.stop)}   ${now.title}', maxLines: 1,
              overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13)),
            const SizedBox(height: 4),
            LinearProgressIndicator(value: now.progress, minHeight: 3),
            if (next != null) Padding(padding: const EdgeInsets.only(top: 4),
              child: Text('${_hm(next.start)}   ${next.title}', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60, fontSize: 11))),
          ])),
        if (!live) Row(children: [
          Text(_fmt(_drag ? Duration(milliseconds: _dragVal.round()) : _pos),
            style: const TextStyle(color: Colors.white, fontSize: 12)),
          Expanded(child: SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7)),
            child: Slider(min: 0, max: max, value: cur,
              onChangeStart: (v) { _drag = true; _dragVal = v; _hideTimer?.cancel(); },
              onChanged: (v) => setState(() => _dragVal = v),
              onChangeEnd: (v) { _drag = false; _player.seek(Duration(milliseconds: v.round())); _showOverlayBriefly(); }))),
          Text(_fmt(_dur), style: const TextStyle(color: Colors.white, fontSize: 12)),
        ]),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (live && widget.playlist.length > 1) _btn(Icons.skip_previous_rounded, '-', () => _step(-1), size: 30),
          if (!live) _btn(Icons.replay_10_rounded, '-10', () => _seekBy(-10), size: 30),
          _btn(_playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded, '▶',
            () => _player.playOrPause(), size: 44),
          if (!live) _btn(Icons.forward_10_rounded, '+10', () => _seekBy(10), size: 30),
          if (live && widget.playlist.length > 1) _btn(Icons.skip_next_rounded, '+', () => _step(1), size: 30),
          const SizedBox(width: 18),
          if (live && widget.playlist.length > 1) _btn(Icons.format_list_numbered_rounded, t('قائمة القنوات'), _openList),
          if (!live) TextButton(onPressed: () { _cycleRate(); _showOverlayBriefly(); },
            child: Text('${_rate}x', style: const TextStyle(color: Colors.white))),
          _btn(Icons.aspect_ratio_rounded, t('نسبة العرض'), _cycleFit),
          _btn(Icons.subtitles_rounded, t('الصوت والترجمة'), _tracksSheet),
          _btn(Icons.more_vert_rounded, '⋮', _menu),
        ]),
      ])));
  }

  Widget _channelPanel() {
    final pl = widget.playlist;
    return Positioned(top: 0, bottom: 0, right: 0, width: 330, child: Container(
      color: const Color(0xEE0B1020),
      child: Column(children: [
        Container(height: 44, padding: const EdgeInsets.symmetric(horizontal: 12), color: Colors.white10,
          child: Row(children: [
            Expanded(child: Text('${t('قائمة القنوات')} (${pl.length})',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
            InkWell(onTap: () => setState(() => _showList = false),
              child: const Icon(Icons.close, color: Colors.white70, size: 20)),
          ])),
        Expanded(child: ListView.builder(controller: _listCtrl, itemExtent: 44, itemCount: pl.length,
          itemBuilder: (_, i) {
            final on = i == _index;
            return InkWell(onTap: () => _switchTo(i), child: Container(
              color: on ? const Color(0x44FFD84D) : null,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                SizedBox(width: 38, child: Text('${i + 1}',
                  style: TextStyle(fontSize: 12, color: on ? const Color(0xFFFFD84D) : Colors.white54))),
                Expanded(child: Text(pl[i].name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: on ? const Color(0xFFFFD84D) : Colors.white))),
              ])));
          })),
      ])));
  }

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgService>();
    final fav = context.watch<LibraryState>().isFavorite(_ch.id);
    final now = epg.now(_ch.epgId), next = epg.next(_ch.epgId);
    return PopScope(
      canPop: !_showList,
      onPopInvokedWithResult: (didPop, _) { if (!didPop && mounted) setState(() => _showList = false); },
      child: Focus(
        focusNode: _focus, autofocus: true, onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: LayoutBuilder(builder: (ctx, box) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleOverlay,
            onDoubleTapDown: (d) => _dtX = d.localPosition.dx,
            onDoubleTap: () => _doubleTap(box.maxWidth),
            onVerticalDragUpdate: (d) {
              if (d.localPosition.dx > box.maxWidth / 2) _changeVolume(-d.delta.dy / 2.0);
            },
            child: Stack(fit: StackFit.expand, children: [
              Video(controller: _controller, fit: _fits[_fit], controls: NoVideoControls),
              if (_buffering && _error == null) const Center(child: CircularProgressIndicator()),
              if (_note != null && _error == null)
                Positioned(top: 64, left: 0, right: 0, child: Center(child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                  child: Text(_note!, style: const TextStyle(color: Colors.white, fontSize: 13))))),
              if (_osd != null)
                Center(child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                  child: Text(_osd!, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)))),
              if (_error != null)
                Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
                    const SizedBox(height: 8),
                    Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: () { _attempt = 0; _triedSoftware = false; _openCurrent(); },
                      child: Text(t('إعادة المحاولة'))),
                  ]))),
              if (_numBuf.isNotEmpty)
                Center(child: Text(_numBuf, style: const TextStyle(
                  fontSize: 72, color: Colors.white, fontWeight: FontWeight.bold))),
              if (_overlay) _topBar(fav),
              if (_overlay) _bottomBar(now, next),
              if (_showList) _channelPanel(),
            ]),
          )),
        ),
      ),
    );
  }
}
