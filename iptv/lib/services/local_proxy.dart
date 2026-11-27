import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'iptv_service.dart';

/// يعيد كتابة قائمة HLS (m3u8) بحيث تمرّ كل الروابط (المقاطع والمفاتيح) عبر [wrap].
String rewriteM3u8(String body, Uri base, String Function(String absoluteUrl) wrap) {
  final out = <String>[];
  for (final raw in body.split(RegExp(r'\r?\n'))) {
    final line = raw.trimRight();
    if (line.isEmpty) {
      out.add(line);
    } else if (line.startsWith('#')) {
      out.add(line.replaceAllMapped(RegExp(r'URI="([^"]*)"'), (m) {
        final u = m[1]!;
        if (u.startsWith('data:')) return m[0]!;
        return 'URI="${wrap(base.resolve(u).toString())}"';
      }));
    } else {
      out.add(wrap(base.resolve(line).toString()));
    }
  }
  return out.join('\n');
}

/// خادم محلي على 127.0.0.1 يخدم صفحة Video.js ويمرّر الوسائط عبر ترويسات المشغّل (User-Agent)
/// ومن نفس الأصل، فلا تظهر مشاكل CORS ولا المحتوى المختلط داخل WebView.
/// محمي برمز عشوائي حتى لا يستعمله تطبيق آخر على الجهاز.
class LocalMediaProxy {
  LocalMediaProxy._();
  static final LocalMediaProxy instance = LocalMediaProxy._();

  HttpServer? _server;
  final String _token = _randomToken();
  late final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..autoUncompress = false
    ..badCertificateCallback = (_, __, ___) => true;

  static String _randomToken() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static String _enc(String s) => base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  static String _dec(String s) => utf8.decode(base64Url.decode(base64Url.normalize(s)));

  Future<int> start() async {
    final s = _server;
    if (s != null) return s.port;
    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = srv;
    srv.listen(_handle, onError: (_) {});
    return srv.port;
  }

  String wrap(String absoluteUrl) => '/p?k=$_token&u=${_enc(absoluteUrl)}';

  String playerUrl(int port, {required String media, required bool live, required int start}) =>
      'http://127.0.0.1:$port/player?k=$_token&u=${_enc(media)}&live=${live ? 1 : 0}&s=$start';

  Future<void> _handle(HttpRequest req) async {
    try {
      final q = req.uri.queryParameters;
      if (q['k'] != _token) {
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }
      if (req.uri.path == '/player') {
        await _servePlayer(req, q);
      } else if (req.uri.path == '/p') {
        await _proxy(req, q);
      } else {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      }
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.badGateway;
        await req.response.close();
      } catch (_) {}
    }
  }

  static String _typeFor(String media) {
    final path = (Uri.tryParse(media)?.path ?? media).toLowerCase();
    if (path.endsWith('.m3u8') || path.contains('.m3u8')) return 'application/x-mpegURL';
    if (path.endsWith('.mkv')) return 'video/x-matroska';
    if (path.endsWith('.ts')) return 'video/mp2t';
    return 'video/mp4';
  }

  Future<void> _servePlayer(HttpRequest req, Map<String, String> q) async {
    final media = _dec(q['u'] ?? '');
    final cfg = jsonEncode({
      'src': wrap(media),
      'type': _typeFor(media),
      'live': q['live'] == '1',
      'start': int.tryParse(q['s'] ?? '') ?? 0,
    });
    final r = req.response;
    r.headers.contentType = ContentType.html;
    r.headers.set('Cache-Control', 'no-store');
    r.write(_playerHtml.replaceFirst('__CFG__', cfg));
    await r.close();
  }

  Future<void> _proxy(HttpRequest req, Map<String, String> q) async {
    final target = Uri.parse(_dec(q['u'] ?? ''));
    final up = await _client.getUrl(target);
    up.followRedirects = true;
    up.maxRedirects = 5;
    kHttpHeaders.forEach((k, v) => up.headers.set(k, v));
    up.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final range = req.headers.value(HttpHeaders.rangeHeader);
    if (range != null) up.headers.set(HttpHeaders.rangeHeader, range);
    final resp = await up.close().timeout(const Duration(seconds: 30));

    final r = req.response;
    r.statusCode = resp.statusCode;
    r.headers.set('Access-Control-Allow-Origin', '*');

    final ct = resp.headers.contentType?.mimeType ?? '';
    final isPlaylist = ct.contains('mpegurl') || target.path.toLowerCase().endsWith('.m3u8');
    if (isPlaylist) {
      final builder = await resp.fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) {
        b.add(d);
        return b;
      });
      final bytes = builder.takeBytes();
      final text = utf8.decode(bytes, allowMalformed: true);
      if (text.trimLeft().startsWith('#EXTM3U')) {
        // الأساس لحلّ الروابط النسبية: العنوان النهائي بعد أي تحويلات
        var base = target;
        for (final info in resp.redirects) {
          base = base.resolveUri(info.location);
        }
        r.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        r.write(rewriteM3u8(text, base, wrap));
      } else {
        if (ct.isNotEmpty) r.headers.set(HttpHeaders.contentTypeHeader, resp.headers.contentType.toString());
        r.add(bytes);
      }
      await r.close();
      return;
    }

    if (ct.isNotEmpty) r.headers.set(HttpHeaders.contentTypeHeader, resp.headers.contentType.toString());
    final cr = resp.headers.value(HttpHeaders.contentRangeHeader);
    if (cr != null) r.headers.set(HttpHeaders.contentRangeHeader, cr);
    final ar = resp.headers.value(HttpHeaders.acceptRangesHeader);
    if (ar != null) r.headers.set(HttpHeaders.acceptRangesHeader, ar);
    if (resp.contentLength >= 0) r.contentLength = resp.contentLength;
    await r.addStream(resp);
    await r.close();
  }
}

const String _playerHtml = r'''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<link href="https://cdn.jsdelivr.net/npm/video.js@8.10.0/dist/video-js.min.css" rel="stylesheet">
<style>
html,body{margin:0;height:100%;background:#000;overflow:hidden}
.video-js{width:100vw;height:100vh}
</style></head>
<body>
<video id="v" class="video-js vjs-big-play-centered" playsinline></video>
<script src="https://cdn.jsdelivr.net/npm/video.js@8.10.0/dist/video.min.js"></script>
<script>
var C = __CFG__;
function send(o){ try { Flutter.postMessage(JSON.stringify(o)); } catch(e){} }
if (typeof videojs === 'undefined') {
  send({t:'error', c:-1, m:'cdn'});
} else {
  var player = videojs('v', {
    autoplay: true, controls: true, preload: 'auto', fill: true, playsinline: true,
    liveui: C.live,
    controlBar: { fullscreenToggle: false, pictureInPictureToggle: false },
    html5: { vhs: { overrideNative: true, enableLowInitialPlaylist: true } },
    sources: [{ src: C.src, type: C.type }]
  });
  var last = 0;
  player.on('loadedmetadata', function(){
    if (!C.live && C.start > 0) { try { player.currentTime(C.start); } catch(e){} }
  });
  player.on('playing', function(){ send({t:'playing'}); });
  player.on('waiting', function(){ send({t:'waiting'}); });
  player.on('timeupdate', function(){
    var n = Date.now();
    if (n - last > 5000) { last = n; send({t:'time', p: player.currentTime(), d: player.duration()}); }
  });
  player.on('error', function(){ var e = player.error() || {}; send({t:'error', c:e.code, m:e.message || ''}); });
  document.addEventListener('touchstart', function(){ send({t:'tap'}); }, {passive:true});
  document.addEventListener('click', function(){ send({t:'tap'}); });
}
</script>
</body></html>''';
