import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/download_manager.dart';
import '../services/epg_service.dart';
import '../services/iptv_service.dart';
import '../services/parental_control.dart';
import '../services/player_diagnostics.dart';
import '../services/player_launcher.dart';
import '../services/subtitle_file.dart';
import '../services/subtitle_translator.dart';
import '../state/app_settings.dart';
import '../state/library_state.dart';
import '../widgets/art.dart';

class PlayerScreen extends StatefulWidget {
  final Channel channel;
  final bool isLive;
  final List<Channel> playlist; // لتبديل القنوات بالريموت
  final List<String> subtitles; // ملفات ترجمة خارجية (للتنزيلات)
  final String? downloadId; // يُمرَّر عند تشغيل ملف محمّل
  final ValueChanged<Channel>? onChannelChanged; // لحفظ القناة الحالية عند التبديل داخل المشغّل

  const PlayerScreen({
    super.key,
    required this.channel,
    this.isLive = true,
    this.playlist = const [],
    this.subtitles = const [],
    this.downloadId,
    this.onChannelChanged,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final Player _player;
  late final VideoController _controller;
  late final LibraryState _lib;
  late final AppSettings _cfg;
  final _focus = FocusNode();
  final _fits = [BoxFit.contain, BoxFit.cover, BoxFit.fill, BoxFit.none, BoxFit.contain, BoxFit.contain];
  final _fitNames = ['احتواء', 'ملء الشاشة', 'تمديد', 'الحجم الأصلي', '16:9', '4:3'];
  final _ratios = <double?>[null, null, null, null, 16 / 9, 4 / 3];
  final _rates = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
  final _subs = <StreamSubscription>[];

  late Channel _ch;
  int _index = 0, _fit = 0, _attempt = 0, _sleepMin = 0, _lastSec = -1;

  List<String> _urls = [];
  late String _decoder;
  bool _buffering = true, _disposed = false, _historyAdded = false, _triedSoftware = false, _overlay = true;
  bool _playing = true, _drag = false, _showList = false;
  String? _error, _note, _osd;
  String _numBuf = '';
  Duration _pos = Duration.zero, _dur = Duration.zero;
  double _dragVal = 0, _volume = 100, _rate = 1.0, _dtX = 0, _bufPct = 0;
  double _dim = 0; // تعتيم الشاشة داخل المشغّل (0 = بدون تعتيم، 0.8 = أقصى)
  bool _muted = false;
  int? _vw, _vh;
  ScrollController? _listCtrl;
  bool _stats = false;
  Timer? _statsTimer;
  String _statsText = '';
  SubtitleTranslator? _translator;
  bool _preBusy = false, _preCancel = false;
  double _prePct = 0;
  double _subSize = 22;
  int _subColor = 0xFFFFFFFF, _subBg = 0x99000000;
  bool _trOn = false;
  String? _trText;
  String _trSrc = '';
  Timer? _hideTimer, _numTimer, _sleepTimer, _osdTimer, _retryTimer;

  // ---- محرّك المراقبة والاسترجاع ----
  final _policy = ReconnectPolicy();
  PlayerDiagnosis? _diag;
  Timer? _watchdog, _switchTimer, _netTimer;
  int _gen = 0, _lastSaved = 0, _progressTicks = 0, _stillTicks = 0;
  bool _handling = false, _everHealthy = false, _blackChecked = false, _behindLive = false;
  DateTime? _bufferingSince, _pausedAt, _netWaitSince;
  Duration _tickPos = const Duration(seconds: -1);
  Duration? _pendingResume;
  String _hlsPref = 'max'; // max | min  (خيار mpv: hls-bitrate)
  String _appliedKey = '';
  double _swipeDx = 0;
  bool _volSide = true;

  bool get _seekable => !widget.isLive && _dur.inMilliseconds > 0;
  bool get _liveLike => widget.isLive || (!_seekable && _everHealthy);

  @override
  void initState() {
    super.initState();
    _lib = context.read<LibraryState>();
    _cfg = context.read<AppSettings>();
    _ch = widget.channel;
    final i = widget.playlist.indexWhere((c) => c.url == _ch.url);
    _index = i < 0 ? 0 : i;
    _fit = _cfg.fit.clamp(0, _fits.length - 1).toInt();
    _decoder = _cfg.decoder;
    _subSize = _cfg.subSize;
    _subColor = _cfg.subColor;
    _subBg = _cfg.subBg;

    WakelockPlus.enable();
    final bufferBytes = (_cfg.effBufferMb.clamp(8, 64)) * 1024 * 1024;
    _player = Player(configuration: PlayerConfiguration(bufferSize: bufferBytes));
    _controller = VideoController(_player);
    _urls = _candidates(_ch.url);

    _subs.add(_player.stream.buffering.listen((b) {
      if (b) {
        _bufferingSince ??= DateTime.now();
      } else {
        _bufferingSince = null;
      }
      if (mounted) setState(() => _buffering = b);
    }));

    _subs.add(_player.stream.playing.listen((p) {
      if (!mounted) return;
      if (widget.isLive) {
        if (!p) {
          _pausedAt ??= DateTime.now();
        } else {
          final pa = _pausedAt;
          _pausedAt = null;
          // بعد توقف طويل على بث مباشر نصبح خلف البث الحالي
          if (pa != null && DateTime.now().difference(pa) > const Duration(seconds: 8)) _behindLive = true;
        }
      }
      setState(() {
        _playing = p;
        if (p && _error != null) _error = null;
      });
    }));

    // انتهاء بث مباشر أو بث بلا مدة يعني أن السيرفر أغلق الاتصال: نعيد الاتصال
    _subs.add(_player.stream.completed.listen((c) {
      if (c && !_disposed && mounted && (widget.isLive || _dur == Duration.zero)) {
        _handleFailure('stream ended');
      }
    }));

    _subs.add(_player.stream.error.listen(_onError));

    _subs.add(_player.stream.bufferingPercentage.listen((v) {
      if (mounted && _buffering && (v - _bufPct).abs() >= 2) {
        setState(() => _bufPct = v);
      }
    }));

    _subs.add(_player.stream.duration.listen((d) {
      final changed = (d.inMilliseconds > 0) != (_dur.inMilliseconds > 0);
      _dur = d;
      if (changed && mounted) setState(() {});
    }));

    _subs.add(_player.stream.width.listen((w) {
      if (mounted && w != _vw) setState(() => _vw = w);
    }));

    _subs.add(_player.stream.height.listen((h) {
      if (mounted && h != _vh) setState(() => _vh = h);
    }));

    _subs.add(_player.stream.position.listen((p) {
      _pos = p;
      if (_seekable) {
        if (p.inSeconds - _lastSaved >= 5 || p.inSeconds < _lastSaved) {
          _lastSaved = p.inSeconds;
          _lib.savePosition(_ch.id, p);
        }
        if (mounted && _overlay && !_drag && p.inSeconds != _lastSec) {
          _lastSec = p.inSeconds;
          setState(() {});
        }
      }
    }));

    _observeSubs();
    _showOverlayBriefly();
    _start();
  }

  /// روابط Xtream المباشرة: جرّب .ts ثم .m3u8 (أو العكس) عند الفشل
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

  Future<void> _applyOptions() async {
    final p = _player.platform as dynamic;
    Future<void> set(String k, String v) async {
      try {
        await p.setProperty(k, v);
      } catch (_) {}
    }

    final live = widget.isLive;
    await set('user-agent', 'ExoPlayerLib/2.19.1 (Linux; Android 13) ExoPlayerDemo/2.19.1');
    await set('hwdec', AppSettings.hwdec(_decoder));

    if (_decoder == 'sw') {
      await set('vd-lavc-fast', 'yes');
      await set('vd-lavc-skiploopfilter', 'nonref');
    }

    if (live) {
      await set('demuxer-lavf-probesize', '1000000');
      await set('demuxer-lavf-analyzeduration', '2');
    }

    await set('network-timeout', live ? '15' : '25');
    await set('tls-verify', 'no');
    await set('sub-codepage', 'utf8:cp1256');
    await set('audio-fallback-to-null', 'yes'); // لا نفشل إذا تعذّر جهاز الصوت

    final pre = _cfg.effPrebufferSec;
    final ahead = live ? 30 : (pre * 3).clamp(30, 300);
    final mb = _cfg.effBufferMb.clamp(8, 64);
    await set('cache', 'yes');
    await set('cache-pause', pre > 0 ? 'yes' : 'no');
    await set('cache-pause-initial', pre > 0 ? 'yes' : 'no');
    final wait = pre <= 0 ? 1 : (live && pre > 4 ? 4 : pre);
    await set('cache-pause-wait', '$wait');
    await set('cache-secs', '$ahead');
    await set('demuxer-readahead-secs', '$ahead');
    await set('demuxer-max-bytes', '${mb * 1024 * 1024}');
    // نحدّ الذاكرة المحجوزة للخلف (ما شاهدناه): في البث المباشر لا فائدة منها
    await set('demuxer-max-back-bytes', '${(live ? 4 : 16) * 1024 * 1024}');
    await set('hls-bitrate', _hlsPref);

    if (_cfg.lite) {
      await set('framedrop', 'decoder+vo');
      await set('vd-lavc-fast', 'yes');
      await set('vd-lavc-skiploopfilter', 'nonref');
    }

    await set('rtsp-transport', 'tcp');
    const reconnect = 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5';
    await set('stream-lavf-o', reconnect);
    await set('demuxer-lavf-o', reconnect);
    _appliedKey = '$_decoder|$_hlsPref';
  }

  /// يعيد ضبط الخيارات فقط عند تغيّر ما يؤثر عليها (يسرّع تبديل القنوات)
  Future<void> _ensureOptions() async {
    if (_appliedKey != '$_decoder|$_hlsPref') await _applyOptions();
  }

  Future<void> _start() async {
    await _applyOptions();
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    await _openCurrent();
  }

  Future<void> _openCurrent() async {
    if (_disposed || !mounted) return;
    _retryTimer?.cancel();
    _netTimer?.cancel();
    final gen = ++_gen;
    _bufferingSince = DateTime.now();
    _pausedAt = null;
    _behindLive = false;
    _everHealthy = false;
    _blackChecked = false;
    _progressTicks = 0;
    _stillTicks = 0;
    _tickPos = const Duration(seconds: -1);
    setState(() {
      _buffering = true;
      _error = null;
    });
    final resume = widget.isLive ? Duration.zero : (_pendingResume ?? _lib.resumePosition(_ch.id));
    _pendingResume = null;
    try {
      await _player.open(Media(_urls[_attempt], start: resume > Duration.zero ? resume : null));
      if (_disposed || !mounted || gen != _gen) return;
      await _player.setRate(_rate);
      if (widget.subtitles.isNotEmpty) {
        // نفضّل النسخة العربية (…_ar_…) ثم آخر ملف مضاف
        final sp = widget.subtitles.lastWhere((p) => p.split(RegExp(r'[\\/]')).last.contains('_ar_'),
            orElse: () => widget.subtitles.last);
        try {
          await _player.setSubtitleTrack(SubtitleTrack.uri(sp, title: sp.split('/').last));
        } catch (_) {}
      }
      if (!_historyAdded) {
        _historyAdded = true;
        _lib.addHistory(_ch);
      }
    } catch (e) {
      if (gen == _gen) _onError('$e');
    }
  }

  void _onError(String e) => _handleFailure(e);

  /// قلب الاسترجاع: تشخيص ← رابط بديل ← فك برمجي ← انتظار الشبكة ← إعادة اتصال محدودة ← رسالة خطأ
  Future<void> _handleFailure(String raw) async {
    if (_disposed || !mounted || raw.isEmpty || _handling) return;
    if ((_retryTimer?.isActive ?? false) || (_netTimer?.isActive ?? false)) return; // معالجة جارية
    _handling = true;
    final gen = _gen;
    PlayerDiagnosis d;
    try {
      d = await diagnosePlayerError(raw, _urls[_attempt]);
    } catch (_) {
      d = classifyPlayerError(raw);
    }
    _handling = false;
    if (_disposed || !mounted || gen != _gen) return;
    _diag = d;

    // 1) رابط بديل (.ts ↔ .m3u8) ما لم تكن المشكلة في الشبكة
    if (_attempt + 1 < _urls.length && d.kind != PlayerFailure.networkUnavailable) {
      _attempt++;
      setState(() => _note = '${t('جارٍ تجربة رابط بديل')} ${_attempt + 1}/${_urls.length}');
      _openCurrent();
      return;
    }
    // 2) فك التشفير البرمجي عند مشاكل الفك أو الصيغة فقط
    if (_decoder != 'sw' &&
        !_triedSoftware &&
        (d.kind == PlayerFailure.playbackFailure || d.kind == PlayerFailure.unsupportedFormat)) {
      _triedSoftware = true;
      _decoder = 'sw';
      _attempt = 0;
      setState(() => _note = t('جارٍ التجربة بفك التشفير البرمجي'));
      await _applyOptions();
      if (_disposed || !mounted || gen != _gen) return;
      _openCurrent();
      return;
    }
    // 3) لا إنترنت: ننتظر عودته دون استهلاك محاولات الاتصال
    if (d.kind == PlayerFailure.networkUnavailable) {
      _waitForNetwork(d);
      return;
    }
    // 4) إعادة اتصال بتأخير متزايد وعدد محدود
    final delay = d.retryable ? _policy.next() : null;
    if (delay == null) {
      _giveUp(d);
      return;
    }
    if (!widget.isLive && _pos > Duration.zero) _pendingResume = _pos; // نكمل من نفس الموضع
    setState(() {
      _buffering = true;
      _note = '${d.title} — ${t('إعادة الاتصال')} (${_policy.attempt}/${_policy.max})...';
    });
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (!_disposed && mounted) {
        _attempt = 0;
        _openCurrent();
      }
    });
  }

  void _giveUp(PlayerDiagnosis d) {
    if (_disposed || !mounted) return;
    _retryTimer?.cancel();
    _netTimer?.cancel();
    setState(() {
      _buffering = false;
      _note = null;
      _diag = d;
      _error = d.message;
    });
  }

  void _waitForNetwork(PlayerDiagnosis d) {
    _netWaitSince ??= DateTime.now();
    setState(() {
      _buffering = true;
      _note = t('لا يوجد اتصال بالإنترنت — بانتظار عودة الشبكة...');
    });
    _netTimer?.cancel();
    _netTimer = Timer.periodic(const Duration(seconds: 4), (tm) async {
      if (_disposed || !mounted) {
        tm.cancel();
        return;
      }
      final since = _netWaitSince ?? DateTime.now();
      if (DateTime.now().difference(since) > const Duration(minutes: 3)) {
        tm.cancel();
        _netWaitSince = null;
        _giveUp(d); // لا ننتظر إلى الأبد
        return;
      }
      if (await hasInternet()) {
        tm.cancel();
        _netWaitSince = null;
        if (_disposed || !mounted) return;
        _policy.reset();
        _attempt = 0;
        _openCurrent();
      }
    });
  }

  /// مراقب يعمل كل ثانية: تعليق التخزين، توقف التقدّم، شاشة سوداء، وتصفير العدّادات عند الاستقرار
  void _tick() {
    if (_disposed || !mounted || _error != null || _preBusy) return;
    if (_handling || (_retryTimer?.isActive ?? false) || (_netTimer?.isActive ?? false)) return;
    final now = DateTime.now();
    final moved = _pos != _tickPos;
    _tickPos = _pos;
    if (moved) {
      _stillTicks = 0;
      if (_playing) _progressTicks++;
    } else {
      _stillTicks++;
    }
    // مؤشر التحميل عالق مع أن الفيديو يتقدّم
    if (_buffering && moved && _progressTicks >= 2) {
      _bufferingSince = null;
      setState(() => _buffering = false);
    }
    if (_progressTicks >= 3) {
      _everHealthy = true;
      if (_note != null) setState(() => _note = null);
    }
    if (_progressTicks >= 8) _policy.reset();

    final bs = _bufferingSince;
    if (_buffering && bs != null) {
      final limit = _everHealthy ? (_liveLike ? 15 : 25) : 30;
      if (now.difference(bs).inSeconds >= limit) {
        _bufferingSince = now;
        _handleFailure('timeout: buffering stalled for ${limit}s');
        return;
      }
    }
    final stillLimit = _liveLike ? 10 : 20;
    if (_playing && !_buffering && _everHealthy && _stillTicks >= stillLimit) {
      _stillTicks = 0;
      _handleFailure('stalled: playback position is not advancing');
      return;
    }
    // صوت بلا صورة (شاشة سوداء): نجرّب فك التشفير البرمجي مرة واحدة فقط
    if (!_blackChecked && _progressTicks >= 10) {
      _blackChecked = true;
      if ((_vw ?? 0) == 0 && _decoder != 'sw' && _player.state.tracks.video.any(_isRealVideo)) {
        _handleFailure('no video output (black screen)');
      }
    }
  }

  /// إعادة تحميل البث الحالي من الصفر (يصفّر المحاولات)
  void _reload() {
    _switchTimer?.cancel();
    _policy.reset();
    _attempt = 0;
    _triedSoftware = false;
    _handling = false;
    if (!widget.isLive && _pos > Duration.zero) _pendingResume = _pos;
    _flash(t('إعادة تحميل البث'));
    _openCurrent();
  }

  /// العودة لموضع البث المباشر الحالي
  void _goLive() {
    _behindLive = false;
    if (_dur > const Duration(seconds: 10)) {
      _player.seek(_dur - const Duration(seconds: 2));
      if (!_playing) _player.play();
      _flash('LIVE');
    } else {
      _reload(); // فتح البث من جديد يبدأ من الحافة الحية
    }
  }

  Future<void> _forceSoftware() async {
    _decoder = 'sw';
    _triedSoftware = true;
    await _applyOptions();
    if (mounted) _reload();
  }

  // ---------- تبديل القنوات ----------
  void _step(int dir) {
    final pl = widget.playlist;
    if (pl.length < 2) return;
    final pc = context.read<ParentalControl>();
    var i = _index;
    for (var n = 0; n < pl.length; n++) {
      i = (i + dir + pl.length) % pl.length;
      if (!pc.isLocked(pl[i].group)) {
        _switchTo(i);
        return;
      }
    }
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
    _policy.reset();
    _triedSoftware = false;
    _decoder = _cfg.decoder;
    _historyAdded = false;
    _handling = false;
    _retryTimer?.cancel();
    _netTimer?.cancel();
    _vw = null;
    _vh = null;
    widget.onChannelChanged?.call(_ch);
    _showOverlayBriefly();
    _flash('${i + 1}  ${_ch.name}');
    setState(() {
      _buffering = true;
      _error = null;
      _note = null;
    });
    // تأخير بسيط: عند التنقل السريع بين القنوات نفتح الأخيرة فقط (بدون تراكم اتصالات)
    _switchTimer?.cancel();
    _switchTimer = Timer(const Duration(milliseconds: 250), () async {
      if (_disposed || !mounted) return;
      await _ensureOptions();
      if (_disposed || !mounted) return;
      _openCurrent();
    });
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
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final live = widget.isLive;
    if (e is KeyRepeatEvent) {
      // الضغط المستمر على اليمين/اليسار يقدّم أو يؤخّر الفيديو تباعاً (الأفلام والحلقات)
      if (!live && (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight)) {
        _seekBy(k == LogicalKeyboardKey.arrowLeft ? -10 : 10);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.channelUp ||
        k == LogicalKeyboardKey.mediaTrackNext) {
      if (live) {
        _step(1);
      } else {
        _showOverlayBriefly();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.channelDown ||
        k == LogicalKeyboardKey.mediaTrackPrevious) {
      if (live) {
        _step(-1);
      } else {
        _showOverlayBriefly();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      if (live) {
        _openList();
      } else {
        _seekBy(-10);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      if (live) {
        _showOverlayBriefly();
      } else {
        _seekBy(10);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPlayPause) {
      _player.playOrPause();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPlay) { _player.play(); _showOverlayBriefly(); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.mediaPause) { _player.pause(); _showOverlayBriefly(); return KeyEventResult.handled; }
    if (!live && k == LogicalKeyboardKey.mediaFastForward) { _seekBy(30); return KeyEventResult.handled; }
    if (!live && k == LogicalKeyboardKey.mediaRewind) { _seekBy(-30); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter || k == LogicalKeyboardKey.gameButtonA) {
      if (!live) {
        _player.playOrPause();
        _showOverlayBriefly();
      } else if (_overlay) {
        _menu();
      } else {
        _showOverlayBriefly();
      }
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
    _osdTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _osd = null);
    });
  }

  void _seekBy(int sec) {
    if (!_seekable) return;
    var target = _player.state.position + Duration(seconds: sec);
    if (target < Duration.zero) target = Duration.zero;
    _player.seek(target);
    _flash(sec < 0 ? '⏪ ${-sec}s' : '${sec}s ⏩');
    _showOverlayBriefly();
  }

  void _changeVolume(double delta) {
    _muted = false;
    _volume = (_volume + delta).clamp(0.0, 100.0).toDouble();
    _player.setVolume(_volume);
    _flash('🔊 ${_volume.round()}%');
  }

  /// السحب العمودي على النصف الأيسر يغيّر السطوع (تعتيم داخل المشغّل 0–80%)
  void _changeBrightness(double delta) {
    _dim = (_dim - delta / 100).clamp(0.0, 0.8).toDouble();
    _flash('🔆 ${((1 - _dim) * 100).round()}%');
  }

  /// نافذة سفلية للتحكم بالصوت أو بسطوع الشاشة (أزرار − / + وشريط تمرير)
  void _levelSheet({required bool volume}) {
    _hideTimer?.cancel();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF101A2A),
      builder: (c) => StatefulBuilder(
        builder: (c, setS) {
          final double lo = volume ? 0.0 : 20.0;
          void upd(VoidCallback f) {
            setState(f);
            setS(() {});
          }

          double current() => volume ? (_muted ? 0.0 : _volume) : (1 - _dim) * 100;

          void setLevel(double nv) {
            final v = nv.clamp(lo, 100.0).toDouble();
            upd(() {
              if (volume) {
                _volume = v;
                _muted = v == 0;
              } else {
                _dim = ((100 - v) / 100).clamp(0.0, 0.8).toDouble();
              }
            });
            if (volume) _player.setVolume(_muted ? 0.0 : _volume);
          }

          final cur = current().clamp(lo, 100.0).toDouble();
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(volume ? Icons.volume_up_rounded : Icons.brightness_6_rounded,
                          color: kAccent3),
                      const SizedBox(width: 10),
                      Text(
                        volume ? t('مستوى الصوت') : t('سطوع الشاشة'),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const Spacer(),
                      if (volume)
                        IconButton(
                          tooltip: t('كتم الصوت'),
                          icon: Icon(_muted ? Icons.volume_off_rounded : Icons.volume_mute_rounded,
                              color: _muted ? const Color(0xFFFFD84D) : Colors.white),
                          onPressed: () {
                            if (_muted && _volume == 0) _volume = 50;
                            upd(() => _muted = !_muted);
                            _player.setVolume(_muted ? 0.0 : _volume);
                          },
                        ),
                    ],
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(volume ? Icons.volume_down_rounded : Icons.brightness_low_rounded),
                        onPressed: () => setLevel(cur - 5),
                      ),
                      Expanded(
                        child: Slider(
                          min: lo,
                          max: 100,
                          divisions: ((100 - lo) / 5).round(),
                          value: cur,
                          label: '${cur.round()}%',
                          onChanged: setLevel,
                        ),
                      ),
                      IconButton(
                        icon: Icon(volume ? Icons.volume_up_rounded : Icons.brightness_high_rounded),
                        onPressed: () => setLevel(cur + 5),
                      ),
                      SizedBox(width: 44, child: Text('${cur.round()}%', textAlign: TextAlign.end)),
                    ],
                  ),
                  if (!volume)
                    Text(
                      t('يخفّض السطوع داخل المشغّل فقط'),
                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(() {
      if (mounted && !_showList) _showOverlayBriefly();
    });
  }

  void _doubleTap(double width) {
    if (widget.isLive || !_seekable) {
      _player.playOrPause();
      return;
    }
    _seekBy(_dtX < width / 2 ? -10 : 10);
  }

  /// نافذة اختيار عامة (قائمة خيارات مع علامة على الحالي)
  void _optionSheet(String title, List<({String label, bool on, VoidCallback tap})> items, {String? footer}) {
    _hideTimer?.cancel();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF101A2A),
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            for (final it in items)
              ListTile(
                dense: true,
                title: Text(it.label),
                trailing: it.on ? const Icon(Icons.check) : null,
                onTap: () {
                  Navigator.pop(c);
                  it.tap();
                },
              ),
            if (footer != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(footer, style: const TextStyle(color: Colors.white54, fontSize: 11)),
              ),
          ],
        ),
      ),
    ).whenComplete(() {
      if (mounted && !_showList) _showOverlayBriefly();
      _focus.requestFocus();
    });
  }

  void _speedSheet() => _optionSheet(t('سرعة التشغيل'), [
        for (final r in _rates)
          (
            label: '${r}x',
            on: r == _rate,
            tap: () {
              setState(() => _rate = r);
              _player.setRate(r);
              _flash('${r}x');
            }
          ),
      ]);

  void _aspectSheet() => _optionSheet(t('نسبة العرض'), [
        for (var i = 0; i < _fits.length; i++)
          (
            label: t(_fitNames[i]),
            on: i == _fit,
            tap: () {
              setState(() => _fit = i);
              _flash(t(_fitNames[i]));
            }
          ),
      ]);

  bool _isRealVideo(VideoTrack v) {
    if (v.id == 'auto' || v.id == 'no') return false;
    try {
      if ((v as dynamic).albumart == true) return false; // غلاف صوتي وليس فيديو
    } catch (_) {}
    return true;
  }

  String _videoTrackName(VideoTrack v) {
    final d = v as dynamic;
    String? title, size;
    int? br;
    try {
      title = d.title as String?;
    } catch (_) {}
    try {
      final w = d.w, h = d.h;
      if (w != null && h != null && h > 0) size = '${w}x$h';
    } catch (_) {}
    try {
      br = d.bitrate as int?;
    } catch (_) {}
    final base = size ?? ((title != null && title.isNotEmpty) ? title : '#${v.id}');
    return br != null && br > 0 ? '$base • ${(br / 1e6).toStringAsFixed(1)} Mbps' : base;
  }

  Future<void> _setHlsPref(String v) async {
    if (_hlsPref == v) return;
    _hlsPref = v;
    await _applyOptions();
    if (mounted) _reload();
  }

  void _qualitySheet() {
    final vids = _player.state.tracks.video.where(_isRealVideo).toList();
    final cur = _player.state.track.video.id;
    final isHls = _urls[_attempt].toLowerCase().contains('.m3u8');
    final multi = vids.length > 1;
    _optionSheet(
      t('الجودة'),
      [
        (
          label: t('تلقائي (أعلى جودة متاحة)'),
          on: _hlsPref == 'max' && (cur == 'auto' || !multi),
          tap: () {
            _player.setVideoTrack(VideoTrack.auto());
            _setHlsPref('max');
          }
        ),
        if (multi)
          for (final v in vids)
            (
              label: _videoTrackName(v),
              on: v.id == cur,
              tap: () {
                _player.setVideoTrack(v);
                _flash(_videoTrackName(v));
              }
            ),
        if (isHls)
          (
            label: t('أقل جودة (توفير البيانات)'),
            on: _hlsPref == 'min',
            tap: () => _setHlsPref('min')
          ),
      ],
      footer: (multi || isHls) ? null : t('لا تتوفر جودات متعددة لهذا البث'),
    );
  }

  Future<void> _infoSheet() async {
    _hideTimer?.cancel();
    final p = _player.platform as dynamic;
    Future<String> g(String k) async {
      try {
        final v = '${await p.getProperty(k)}';
        return v.isEmpty || v == 'null' ? '-' : v;
      } catch (_) {
        return '-';
      }
    }

    String num1(String v) {
      final d = double.tryParse(v);
      return d == null ? v : d.toStringAsFixed(1);
    }

    final br = double.tryParse(await g('video-bitrate'));
    final type = widget.isLive ? t('بث مباشر') : (_seekable ? t('فيديو (VOD)') : t('بث بدون مدة'));
    final rows = <MapEntry<String, String>>[
      MapEntry(t('القناة'), _ch.name),
      MapEntry(t('الرابط'), maskUrl(_urls[_attempt])),
      MapEntry(t('النوع'), type),
      MapEntry(t('الحاوية'), await g('file-format')),
      MapEntry(t('الفيديو'), '${await g('video-codec')}  ${_vw ?? '-'}x${_vh ?? '-'}  ${num1(await g('container-fps'))} fps'),
      MapEntry(t('الصوت'), await g('audio-codec-name')),
      MapEntry(t('معدل البيانات'), br == null ? '-' : '${(br / 1e6).toStringAsFixed(2)} Mbps'),
      MapEntry(t('فك التشفير'), '${await g('hwdec-current')}  (${_decoderLabel()})'),
      MapEntry(t('التخزين المؤقت'), '${num1(await g('demuxer-cache-duration'))} s'),
      MapEntry(t('الإطارات المُسقطة'), await g('frame-drop-count')),
      MapEntry(t('إعادة الاتصال'), '${_policy.attempt}/${_policy.max}'),
    ];
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF101A2A),
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(t('معلومات البث'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            for (final r in rows)
              ListTile(
                dense: true,
                title: Text(r.key, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                subtitle: SelectableText(r.value, style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
          ],
        ),
      ),
    );
    if (mounted && !_showList) _showOverlayBriefly();
    _focus.requestFocus();
  }

  void _openList() {
    if (widget.playlist.length < 2) {
      _showOverlayBriefly();
      return;
    }
    _listCtrl?.dispose();
    _listCtrl = ScrollController(
      initialScrollOffset: (_index * 44.0 - 120).clamp(0.0, double.infinity).toDouble(),
    );
    setState(() => _showList = true);
    _hideTimer?.cancel();
  }

  // ---------- الواجهة ----------
  void _showOverlayBriefly() {
    _hideTimer?.cancel();
    if (mounted) setState(() => _overlay = true);
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_drag) setState(() => _overlay = false);
    });
  }

  void _toggleOverlay() {
    if (_showList) {
      setState(() => _showList = false);
      return;
    }
    if (_overlay) {
      _hideTimer?.cancel();
      setState(() => _overlay = false);
    } else {
      _showOverlayBriefly();
    }
  }

  Future<void> _cycleDecoder() async {
    const order = ['auto', 'hw', 'sw'];
    _decoder = order[(order.indexOf(_decoder) + 1) % order.length];
    _attempt = 0;
    _policy.reset();
    _triedSoftware = _decoder == 'sw';
    setState(() => _note = '${t('وضع فك التشفير')}: ${_decoderLabel()}');
    await _applyOptions();
    await _openCurrent();
  }

  String _decoderLabel() => _decoder == 'hw'
      ? t('عتاد (Hardware)')
      : _decoder == 'sw'
          ? t('برمجي (Software)')
          : t('تلقائي');

  void _cycleSleep() {
    const opts = [0, 15, 30, 60, 90];
    _sleepMin = opts[(opts.indexOf(_sleepMin) + 1) % opts.length];
    _sleepTimer?.cancel();
    if (_sleepMin > 0) {
      _sleepTimer = Timer(Duration(minutes: _sleepMin), () {
        if (mounted) Navigator.pop(context);
      });
    }
    setState(() => _note = _sleepMin == 0 ? t('مؤقّت النوم') : '${t('مؤقّت النوم')}: $_sleepMin');
  }

  static const _langNames = {
    'ar': 'العربية', 'en': 'English', 'fr': 'Français', 'es': 'Español', 'de': 'Deutsch', 'tr': 'Türkçe',
    'it': 'Italiano', 'ru': 'Русский', 'fa': 'فارسی', 'ur': 'اردو', 'hi': 'हिन्दी', 'pt': 'Português',
    'ku': 'Kurdî', 'zh': '中文', 'ja': '日本語', 'ko': '한국어',
  };
  static const _lang3 = {
    'ara': 'ar', 'eng': 'en', 'fre': 'fr', 'fra': 'fr', 'spa': 'es', 'ger': 'de', 'deu': 'de', 'tur': 'tr',
    'ita': 'it', 'rus': 'ru', 'per': 'fa', 'fas': 'fa', 'por': 'pt', 'urd': 'ur', 'hin': 'hi', 'kur': 'ku',
    'chi': 'zh', 'zho': 'zh', 'jpn': 'ja', 'kor': 'ko',
  };

  String? _langName(String? l) {
    if (l == null || l.isEmpty) return null;
    final k = l.toLowerCase().split(RegExp(r'[-_]')).first;
    return _langNames[_lang3[k] ?? k] ?? l;
  }

  String _trackName(String id, String? title, String? lang) {
    if (id == 'auto') return t('تلقائي');
    if (id == 'no') return t('إيقاف');
    final ln = _langName(lang);
    final parts = [
      if (title != null && title.isNotEmpty && title != ln) title,
      if (ln != null) ln,
    ];
    return parts.isEmpty ? '#$id' : parts.join(' • ');
  }

  void _toggleStats() {
    setState(() => _stats = !_stats);
    _statsTimer?.cancel();
    if (_stats) {
      _pollStats();
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _pollStats());
    }
  }

  Future<void> _pollStats() async {
    final p = _player.platform as dynamic;
    Future<String> g(String k) async {
      try {
        return '${await p.getProperty(k)}';
      } catch (_) {
        return '-';
      }
    }

    String num1(String v) {
      final d = double.tryParse(v);
      return d == null ? v : d.toStringAsFixed(1);
    }

    final hw = await g('hwdec-current');
    final fmt = await g('video-format');
    final fps = num1(await g('estimated-vf-fps'));
    final dropV = await g('frame-drop-count');
    final dropD = await g('decoder-frame-drop-count');
    final cache = num1(await g('demuxer-cache-duration'));
    final br = double.tryParse(await g('video-bitrate'));
    if (!mounted || !_stats) return;
    setState(() => _statsText =
        'Decoder: $hw ($fmt)\nFPS: $fps   Dropped: $dropD/$dropV\n'
        'Buffer: ${cache}s   Bitrate: ${br == null ? '-' : '${(br / 1e6).toStringAsFixed(2)} Mbps'}');
  }

  void _observeSubs() {
    _subs.add(_player.stream.subtitle.listen((lines) => _onSubText(lines.join('\n'))));
  }

  void _onSubText(String v) {
    if (!_trOn || !mounted) return;
    final src = SubtitleTranslator.clean(v);
    if (src == _trSrc) return;
    _trSrc = src;
    if (src.isEmpty) {
      if (_trText != null) setState(() => _trText = null);
      return;
    }
    _translator!.translate(src).then((r) {
      if (!mounted || !_trOn || _trSrc != src) return;
      setState(() => _trText = r ?? src);
    });
  }

  Future<void> _toggleTranslate() async {
    if (_trOn) {
      setState(() {
        _trOn = false;
        _trText = null;
      });
      _flash(t('إيقاف التعريب'));
      return;
    }
    final cur = _player.state.track.subtitle.id;
    if (cur == 'no' || cur == 'auto') {
      final subs = _player.state.tracks.subtitle.where((s) => s.id != 'auto' && s.id != 'no').toList();
      if (subs.isEmpty) {
        _flash(t('لا توجد ترجمة في هذا الفيديو — أضف ملف ترجمة'));
        return;
      }
      final en = subs.where((s) => (s.language ?? '').toLowerCase().startsWith('en')).toList();
      await _player.setSubtitleTrack(en.isNotEmpty ? en.first : subs.first);
    }
    _translator ??= SubtitleTranslator(target: currentSubLang());
    if (!mounted) return;
    setState(() => _trOn = true);
    _trSrc = '';
    _onSubText(_player.state.subtitle.join('\n'));
    _flash(t('تعريب الترجمة: تشغيل'));
  }

  Future<void> _applySubStyle() async {}

  SubtitleViewConfiguration get _subCfg {
    final clear = ((_subBg >> 24) & 0xFF) == 0;
    return SubtitleViewConfiguration(
      visible: !_trOn,
      style: TextStyle(
        height: 1.3,
        fontSize: _subSize,
        color: Color(_subColor),
        fontWeight: FontWeight.w600,
        backgroundColor: Color(_subBg),
        shadows: clear
            ? const [
                Shadow(blurRadius: 4, color: Colors.black, offset: Offset(1.5, 1.5)),
                Shadow(blurRadius: 4, color: Colors.black, offset: Offset(-1.5, -1.5)),
              ]
            : null,
      ),
      textAlign: TextAlign.center,
    );
  }

  Widget _subText(String text) {
    final clear = ((_subBg >> 24) & 0xFF) == 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(color: Color(_subBg), borderRadius: BorderRadius.circular(6)),
      child: Text(
        text,
        textAlign: TextAlign.center,
        textDirection: TextDirection.rtl,
        style: TextStyle(
          color: Color(_subColor),
          fontSize: _subSize,
          height: 1.3,
          fontWeight: FontWeight.w600,
          shadows: clear
              ? const [
                  Shadow(blurRadius: 4, color: Colors.black, offset: Offset(1.5, 1.5)),
                  Shadow(blurRadius: 4, color: Colors.black, offset: Offset(-1.5, -1.5)),
                ]
              : null,
        ),
      ),
    );
  }

  void _styleSheet() {
    const textColors = [0xFFFFFFFF, 0xFFFFD84D, 0xFF7CFF8C, 0xFF6FE7FF];
    const backgrounds = [0x00000000, 0x80000000, 0xFF000000, 0xCC0B3D91, 0xCC0B5D1E, 0xCC8B1A1A, 0xCCFFD84D];
    _hideTimer?.cancel();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF101A2A),
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(
        builder: (c, setS) {
          void upd(VoidCallback f) {
            setState(f);
            setS(() {});
            _cfg.saveSubStyle(_subSize, _subColor, _subBg);
            _applySubStyle();
          }

          Widget swatch(int v, bool on, VoidCallback f) => GestureDetector(
                onTap: f,
                child: Container(
                  width: 34,
                  height: 34,
                  margin: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: Color(v),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: on ? const Color(0xFFFFD84D) : Colors.white38,
                      width: on ? 3 : 1,
                    ),
                  ),
                  child: ((v >> 24) & 0xFF) == 0
                      ? const Icon(Icons.block, size: 18, color: Colors.white70)
                      : null,
                ),
              );

          return SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t('حجم الترجمة وألوانها'),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.text_decrease_rounded),
                          onPressed: () =>
                              upd(() => _subSize = (_subSize - 2).clamp(12.0, 48.0).toDouble()),
                        ),
                        Expanded(
                          child: Slider(
                            min: 12,
                            max: 48,
                            divisions: 36,
                            value: _subSize,
                            label: _subSize.round().toString(),
                            onChanged: (v) => upd(() => _subSize = v),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.text_increase_rounded),
                          onPressed: () =>
                              upd(() => _subSize = (_subSize + 2).clamp(12.0, 48.0).toDouble()),
                        ),
                        Text('${_subSize.round()}'),
                      ],
                    ),
                    Text(t('لون النص'), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    Wrap(
                      children: [
                        for (final v in textColors)
                          swatch(v, v == _subColor, () => upd(() => _subColor = v)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(t('الخلفية'), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    Wrap(
                      children: [
                        for (final v in backgrounds)
                          swatch(v, v == _subBg, () => upd(() => _subBg = v)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF3A4252),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(child: _subText(t('نص تجريبي'))),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ).then((_) {
      _showOverlayBriefly();
      _focus.requestFocus();
    });
  }

  Future<void> _preTranslate() async {
    if (_preBusy) return;
    String? src;
    for (final p in widget.subtitles) {
      if (!p.endsWith('_ar.srt') && !p.split(RegExp(r'[\\/]')).last.contains('_ar_')) src = p;
    }
    if (src == null) {
      final r = await FilePicker.platform.pickFiles(type: FileType.any);
      src = r?.files.single.path;
      if (src == null || !mounted) return;
    }
    final ext = src.split('.').last.toLowerCase();
    if (!const ['srt', 'vtt', 'ass', 'ssa'].contains(ext)) {
      _flash(t('صيغة الترجمة غير مدعومة'));
      return;
    }
    await _player.pause();
    if (!mounted) return;
    setState(() {
      _preBusy = true;
      _preCancel = false;
      _prePct = 0;
      _showList = false;
    });
    try {
      final bytes = await File(src).readAsBytes();
      final cues = parseSubtitle(decodeSubtitle(bytes), ext);
      if (cues.isEmpty) throw Exception('empty');
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/translated_subs');
      await dir.create(recursive: true);
      final out = File('${dir.path}/${md5.convert(bytes).toString().substring(0, 12)}_ar.srt');
      if (!await out.exists()) {
        final tr = _translator ??= SubtitleTranslator(target: currentSubLang());
        final map = await tr.translateAll(
          cues.map((c) => c.text).toList(),
          onProgress: (p) {
            if (mounted) setState(() => _prePct = p);
          },
          isCancelled: () => _preCancel,
        );
        if (_preCancel) return;
        for (final c in cues) {
          c.text = map[SubtitleTranslator.clean(c.text)] ?? SubtitleTranslator.clean(c.text);
        }
        await out.writeAsString(toSrt(cues));
      }
      var path = out.path;
      final id = widget.downloadId;
      if (id != null && mounted) path = await context.read<DownloadManager>().addSubtitle(id, out.path);
      if (!mounted) return;
      _trOn = false;
      _trText = null;
      await _player.setSubtitleTrack(SubtitleTrack.uri(path, title: 'العربية', language: 'ar'));
      _flash(t('اكتملت ترجمة الفيلم'));
    } catch (_) {
      _flash(t('تعذر ترجمة الملف'));
    } finally {
      if (mounted) setState(() => _preBusy = false);
      if (!_disposed) {
        try {
          await _player.play();
        } catch (_) {}
      }
    }
  }

  Future<void> _pickSubtitle() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = r?.files.single.path;
    if (path == null || !mounted) return;
    final ext = path.split('.').last.toLowerCase();
    if (!const ['srt', 'vtt', 'ass', 'ssa', 'sub'].contains(ext)) {
      _flash(t('صيغة الترجمة غير مدعومة'));
      return;
    }
    var use = path;
    final id = widget.downloadId;
    if (id != null) use = await context.read<DownloadManager>().addSubtitle(id, path);
    try {
      await _player.setSubtitleTrack(SubtitleTrack.uri(use, title: use.split('/').last));
      _flash(t('تمت إضافة الترجمة'));
    } catch (_) {
      _flash(t('تعذر تحميل الترجمة'));
    }
  }

  Future<void> _download() async {
    final ok = await context.read<DownloadManager>().enqueue(_ch);
    _flash(ok ? t('بدأ التحميل') : t('هذا الرابط لا يدعم التحميل'));
  }

  void _tracksSheet() {
    final tr = _player.state.tracks;
    final curA = _player.state.track.audio.id, curS = _player.state.track.subtitle.id;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF101A2A),
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            if (!widget.isLive)
              ListTile(
                dense: true,
                leading: const Icon(Icons.auto_fix_high_rounded),
                title: Text(t('ترجمة ملف الترجمة كاملاً قبل التشغيل')),
                onTap: () {
                  Navigator.pop(c);
                  _preTranslate();
                },
              ),
            if (!widget.isLive)
              ListTile(
                dense: true,
                leading: const Icon(Icons.upload_file_rounded),
                title: Text(t('إضافة ملف ترجمة')),
                onTap: () {
                  Navigator.pop(c);
                  _pickSubtitle();
                },
              ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(t('الصوت'), style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            for (final a in tr.audio)
              ListTile(
                dense: true,
                title: Text(_trackName(a.id, a.title, a.language)),
                trailing: a.id == curA ? const Icon(Icons.check) : null,
                onTap: () {
                  _player.setAudioTrack(a);
                  Navigator.pop(c);
                },
              ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(t('الترجمة'), style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.subtitles_off_rounded, size: 20),
              title: Text(t('إيقاف الترجمة')),
              trailing: curS == 'no' ? const Icon(Icons.check) : null,
              onTap: () {
                _player.setSubtitleTrack(SubtitleTrack.no());
                Navigator.pop(c);
              },
            ),
            for (final s in tr.subtitle.where((s) => s.id != 'no'))
              ListTile(
                dense: true,
                title: Text(_trackName(s.id, s.title, s.language)),
                trailing: s.id == curS ? const Icon(Icons.check) : null,
                onTap: () {
                  _player.setSubtitleTrack(s);
                  Navigator.pop(c);
                },
              ),
          ],
        ),
      ),
    ).then((_) => _focus.requestFocus());
  }

  void _menu() {
    final fav = _lib.isFavorite(_ch.id);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF101A2A),
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: Icon(fav ? Icons.star : Icons.star_border),
              title: Text(fav ? t('أزيلت من المفضلة') : t('أضيفت إلى المفضلة')),
              onTap: () {
                _lib.toggleFavorite(_ch);
                Navigator.pop(c);
              },
            ),
            if (widget.isLive && widget.playlist.length > 1)
              ListTile(
                leading: const Icon(Icons.format_list_numbered),
                title: Text(t('قائمة القنوات')),
                onTap: () {
                  Navigator.pop(c);
                  _openList();
                },
              ),
            if (!widget.isLive && widget.downloadId == null)
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: Text(t('تحميل للمشاهدة بدون إنترنت')),
                onTap: () {
                  Navigator.pop(c);
                  _download();
                },
              ),
            if (!widget.isLive)
              ListTile(
                leading: const Icon(Icons.auto_fix_high_rounded),
                title: Text(t('ترجمة ملف الترجمة كاملاً قبل التشغيل')),
                onTap: () {
                  Navigator.pop(c);
                  _preTranslate();
                },
              ),
            ListTile(
              leading: const Icon(Icons.speed_rounded),
              title: Text(t('إحصائيات التشغيل')),
              onTap: () {
                Navigator.pop(c);
                _toggleStats();
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: Text(t('معلومات البث')),
              onTap: () {
                Navigator.pop(c);
                _infoSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.high_quality_rounded),
              title: Text(t('الجودة')),
              onTap: () {
                Navigator.pop(c);
                _qualitySheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.refresh_rounded),
              title: Text(t('إعادة تحميل البث')),
              onTap: () {
                Navigator.pop(c);
                _reload();
              },
            ),
            ListTile(
              leading: const Icon(Icons.text_fields_rounded),
              title: Text(t('حجم الترجمة وألوانها')),
              onTap: () {
                Navigator.pop(c);
                _styleSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.translate),
              title: Text(_trOn ? t('إيقاف التعريب') : t('تعريب الترجمة')),
              onTap: () {
                Navigator.pop(c);
                _toggleTranslate();
              },
            ),
            ListTile(
              leading: const Icon(Icons.subtitles),
              title: Text(t('الصوت والترجمة')),
              onTap: () {
                Navigator.pop(c);
                _tracksSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.memory),
              title: Text('${t('وضع فك التشفير')}: ${_decoderLabel()}'),
              onTap: () {
                Navigator.pop(c);
                _cycleDecoder();
              },
            ),
            ListTile(
              leading: const Icon(Icons.aspect_ratio),
              title: Text('${t('نسبة العرض')}: ${t(_fitNames[_fit])}'),
              onTap: () {
                Navigator.pop(c);
                _aspectSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.bedtime),
              title: Text(_sleepMin == 0 ? t('مؤقّت النوم') : '${t('مؤقّت النوم')}: $_sleepMin'),
              onTap: () {
                Navigator.pop(c);
                _cycleSleep();
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new_rounded),
              title: const Text('MX Player'),
              onTap: () async {
                Navigator.pop(c);
                final opened = await openPlayer(context, _ch,
                    live: widget.isLive, playlist: widget.playlist,
                    player: 'mx', fallbackToInternal: false);
                if (opened && mounted) _player.pause();
              },
            ),
          ],
        ),
      ),
    ).then((_) => _focus.requestFocus());
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
    _hideTimer?.cancel();
    _numTimer?.cancel();
    _sleepTimer?.cancel();
    _osdTimer?.cancel();
    _statsTimer?.cancel();
    _retryTimer?.cancel();
    _switchTimer?.cancel();
    _watchdog?.cancel();
    _netTimer?.cancel();
    _focus.dispose();
    _listCtrl?.dispose();
    _translator?.flush();
    if (_seekable) _lib.savePosition(_ch.id, _player.state.position);
    for (final s in _subs) {
      s.cancel();
    }
    WakelockPlus.disable();
    // تحرير المشغّل وموارد الوسائط دون أن يتسبب أي خطأ في إغلاق التطبيق
    try {
      unawaited(_player.dispose().catchError((_) {}));
    } catch (_) {}
    super.dispose();
  }

  IconData _errIcon() => switch (_diag?.kind) {
        PlayerFailure.networkUnavailable => Icons.wifi_off_rounded,
        PlayerFailure.timeout => Icons.timer_off_rounded,
        PlayerFailure.invalidStream => Icons.link_off_rounded,
        PlayerFailure.unsupportedFormat => Icons.videocam_off_rounded,
        PlayerFailure.serverUnavailable => Icons.cloud_off_rounded,
        _ => Icons.error_outline,
      };

  Widget _btn(IconData i, String tip, VoidCallback f, {double size = 26, Color color = Colors.white}) =>
      IconButton(
        icon: Icon(i, color: color, size: size),
        tooltip: tip,
        onPressed: () {
          f();
          if (!_showList) _showOverlayBriefly();
        },
      );

  Widget _chip(String s) => Container(
        margin: const EdgeInsets.only(left: 6, right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(6)),
        child: Text(s, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
      );

  /// مؤشر LIVE: أحمر عند البث الحالي، ورمادي «الذهاب للمباشر» عند التأخر؛ الضغط يعيدنا للمباشر
  Widget _liveChip() {
    final atLive = !_behindLive;
    return GestureDetector(
      onTap: () {
        _goLive();
        _showOverlayBriefly();
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: atLive ? const Color(0xFFE53935) : Colors.white24,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 8, color: atLive ? Colors.white : Colors.redAccent),
            const SizedBox(width: 4),
            Text(
              atLive ? 'LIVE' : t('الذهاب للمباشر'),
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar(bool fav) => Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 22),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          child: Row(
            children: [
              _btn(Icons.arrow_back_rounded, t('رجوع'), () => Navigator.pop(context), size: 24),
              if (widget.isLive && widget.playlist.length > 1)
                Container(
                  margin: const EdgeInsetsDirectional.only(end: 10),
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF8A00),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('${_index + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              Expanded(
                child: Text(
                  _ch.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              if (_quality != null) _chip(_quality!),
              if (_liveLike) _liveChip(),
              _btn(_muted || _volume == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                  t('مستوى الصوت'), () => _levelSheet(volume: true),
                  size: 24, color: _muted ? const Color(0xFFFFD84D) : Colors.white),
              _btn(Icons.brightness_6_rounded, t('سطوع الشاشة'), () => _levelSheet(volume: false),
                  size: 24, color: _dim > 0 ? const Color(0xFFFFD84D) : Colors.white),
              _btn(fav ? Icons.star : Icons.star_border, t('المفضلة'), () => _lib.toggleFavorite(_ch), size: 22),
              _btn(Icons.close, 'X', () => Navigator.pop(context), size: 22),
            ],
          ),
        ),
      );

  Widget _bottomBar(Program? now, Program? next) {
    final live = widget.isLive;
    final total = _dur.inMilliseconds.toDouble();
    final max = total <= 0 ? 1.0 : total;
    final cur = (_drag ? _dragVal : _pos.inMilliseconds.toDouble()).clamp(0.0, max).toDouble();
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (live && now != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_hm(now.start)} – ${_hm(now.stop)}   ${now.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(value: now.progress, minHeight: 3),
                    if (next != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${_hm(next.start)}   ${next.title}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white60, fontSize: 11),
                        ),
                      ),
                  ],
                ),
              ),
            if (!live && !_seekable && _pos > Duration.zero)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(_fmt(_pos), style: const TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ),
            if (_seekable)
              Row(
                children: [
                  Text(
                    _fmt(_drag ? Duration(milliseconds: _dragVal.round()) : _pos),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                      ),
                      child: Slider(
                        min: 0,
                        max: max,
                        value: cur,
                        onChangeStart: (v) {
                          _drag = true;
                          _dragVal = v;
                          _hideTimer?.cancel();
                        },
                        onChanged: (v) => setState(() => _dragVal = v),
                        onChangeEnd: (v) {
                          _drag = false;
                          _player.seek(Duration(milliseconds: v.round()));
                          _showOverlayBriefly();
                        },
                      ),
                    ),
                  ),
                  Text(_fmt(_dur), style: const TextStyle(color: Colors.white, fontSize: 12)),
                ],
              ),
            LayoutBuilder(
              builder: (ctx, box) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: box.maxWidth),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (live && widget.playlist.length > 1)
                        _btn(Icons.skip_previous_rounded, '-', () => _step(-1), size: 30),
                      if (_seekable) _btn(Icons.replay_10_rounded, '-10', () => _seekBy(-10), size: 30),
                      _btn(
                        _playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                        '▶',
                        () => _player.playOrPause(),
                        size: 44,
                      ),
                      if (_seekable) _btn(Icons.forward_10_rounded, '+10', () => _seekBy(10), size: 30),
                      if (live && widget.playlist.length > 1)
                        _btn(Icons.skip_next_rounded, '+', () => _step(1), size: 30),
                      const SizedBox(width: 18),
                      if (_liveLike) _liveChip(),
                      if (live && widget.playlist.length > 1)
                        _btn(Icons.format_list_numbered_rounded, t('قائمة القنوات'), _openList),
                      if (_seekable)
                        TextButton(
                          onPressed: () {
                            _speedSheet();
                            _showOverlayBriefly();
                          },
                          child: Text('${_rate}x', style: const TextStyle(color: Colors.white)),
                        ),
                      _btn(Icons.aspect_ratio_rounded, t('نسبة العرض'), _aspectSheet),
                      _btn(Icons.subtitles_rounded, t('الصوت والترجمة'), _tracksSheet),
                      _btn(Icons.high_quality_rounded, t('الجودة'), _qualitySheet),
                      _btn(Icons.refresh_rounded, t('إعادة تحميل البث'), _reload),
                      _btn(Icons.info_outline_rounded, t('معلومات البث'), _infoSheet),
                      _btn(Icons.text_fields_rounded, t('حجم الترجمة وألوانها'), _styleSheet),
                      _btn(
                        Icons.translate_rounded,
                        t('تعريب الترجمة'),
                        _toggleTranslate,
                        color: _trOn ? const Color(0xFFFFD84D) : Colors.white,
                      ),
                      _btn(Icons.more_vert_rounded, '⋮', _menu),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _channelPanel() {
    final pl = widget.playlist;
    return Positioned(
      top: 0,
      bottom: 0,
      right: 0,
      width: 330,
      child: Container(
        color: const Color(0xEE0B1020),
        child: Column(
          children: [
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              color: Colors.white10,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${t('قائمة القنوات')} (${pl.length})',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ),
                  InkWell(
                    onTap: () => setState(() => _showList = false),
                    child: const Icon(Icons.close, color: Colors.white70, size: 20),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: _listCtrl,
                itemExtent: 44,
                itemCount: pl.length,
                itemBuilder: (_, i) {
                  final on = i == _index;
                  return InkWell(
                    onTap: () => _switchTo(i),
                    child: Container(
                      color: on ? const Color(0x44FFD84D) : null,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 38,
                            child: Text(
                              '${i + 1}',
                              style: TextStyle(
                                fontSize: 12,
                                color: on ? const Color(0xFFFFD84D) : Colors.white54,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              pl[i].name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: on ? const Color(0xFFFFD84D) : Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgService>();
    final fav = context.watch<LibraryState>().isFavorite(_ch.id);
    final now = epg.now(_ch.epgId), next = epg.next(_ch.epgId);

    return PopScope(
      canPop: !_showList,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && mounted) setState(() => _showList = false);
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: LayoutBuilder(
            builder: (ctx, box) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleOverlay,
              onDoubleTapDown: (d) => _dtX = d.localPosition.dx,
              onDoubleTap: () => _doubleTap(box.maxWidth),
              onVerticalDragStart: (d) => _volSide = d.localPosition.dx > box.maxWidth / 2,
              onVerticalDragUpdate: (d) {
                if (_volSide) {
                  _changeVolume(-d.delta.dy / 2.0);
                } else {
                  _changeBrightness(-d.delta.dy / 2.0);
                }
              },
              // السحب الأفقي: تبديل القنوات في البث المباشر فقط
              onHorizontalDragStart: (_) => _swipeDx = 0,
              onHorizontalDragUpdate: (d) => _swipeDx += d.delta.dx,
              onHorizontalDragEnd: (d) {
                final v = d.primaryVelocity ?? 0;
                final dx = _swipeDx;
                _swipeDx = 0;
                if (!widget.isLive || widget.playlist.length < 2) return;
                if (dx.abs() > 90 || v.abs() > 900) _step((dx != 0 ? dx : v) < 0 ? 1 : -1);
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Video(
                    controller: _controller,
                    fit: _fits[_fit],
                    aspectRatio: _ratios[_fit],
                    controls: NoVideoControls,
                    subtitleViewConfiguration: _subCfg,
                  ),
                  if (_dim > 0)
                    Positioned.fill(
                      child: IgnorePointer(child: ColoredBox(color: Color.fromRGBO(0, 0, 0, _dim))),
                    ),
                  if (_buffering && _error == null)
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          if (_bufPct > 0 && _bufPct < 100)
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Text(
                                '${t('جارٍ التخزين')} ${_bufPct.round()}%',
                                style: const TextStyle(color: Colors.white70, fontSize: 13),
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (_note != null && _error == null)
                    Positioned(
                      top: 64,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(_note!, style: const TextStyle(color: Colors.white, fontSize: 13)),
                        ),
                      ),
                    ),
                  if (_osd != null)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          _osd!,
                          style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  if (_error != null)
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 520),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(_errIcon(), color: Colors.redAccent, size: 48),
                              const SizedBox(height: 8),
                              Text(
                                _diag?.title ?? t('فشل التشغيل'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 6),
                              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                              if (_diag != null && _diag!.raw.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    _diag!.raw,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Colors.white30, fontSize: 10),
                                  ),
                                ),
                              const SizedBox(height: 14),
                              Wrap(
                                spacing: 10,
                                runSpacing: 8,
                                alignment: WrapAlignment.center,
                                children: [
                                  FilledButton(onPressed: _reload, child: Text(t('إعادة المحاولة'))),
                                  if (_decoder != 'sw')
                                    OutlinedButton(
                                      onPressed: _forceSoftware,
                                      child: Text(t('فك التشفير البرمجي')),
                                    ),
                                  OutlinedButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: Text(t('رجوع')),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_trOn && _trText != null && _error == null)
                    Positioned(
                      left: 48,
                      right: 48,
                      bottom: _overlay ? 118 : 34,
                      child: IgnorePointer(child: Center(child: _subText(_trText!))),
                    ),
                  if (_preBusy)
                    Positioned.fill(
                      child: GestureDetector(
                        onTap: () {},
                        child: Container(
                          color: Colors.black87,
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.translate_rounded, size: 40, color: Colors.white70),
                                const SizedBox(height: 14),
                                Text(
                                  '${t('جارٍ ترجمة الترجمة')} ${(_prePct * 100).round()}%',
                                  style: const TextStyle(color: Colors.white, fontSize: 18),
                                ),
                                const SizedBox(height: 12),
                                SizedBox(
                                  width: 280,
                                  child: LinearProgressIndicator(value: _prePct, minHeight: 5),
                                ),
                                const SizedBox(height: 16),
                                OutlinedButton(
                                  onPressed: () => setState(() => _preCancel = true),
                                  child: Text(t('إلغاء')),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_stats)
                    Positioned(
                      top: 64,
                      left: 16,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _statsText.isEmpty ? '...' : _statsText,
                            style: const TextStyle(
                              color: Color(0xFF7CFF8C),
                              fontSize: 11,
                              fontFamily: 'monospace',
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_numBuf.isNotEmpty)
                    Center(
                      child: Text(
                        _numBuf,
                        style: const TextStyle(fontSize: 72, color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                  if (_overlay) _topBar(fav),
                  if (_overlay) _bottomBar(now, next),
                  if (_showList) _channelPanel(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
