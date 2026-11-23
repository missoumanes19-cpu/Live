import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import '../config.dart';
import 'iptv_service.dart';

class GhServer {
  final String name;
  final String? host, user, pass, m3u;
  GhServer(this.name, {this.host, this.user, this.pass, this.m3u});
}

class GithubConfig {
  final String fingerprint, name, message, minVersion, updateUrl, epgUrl, latestVersion;
  final bool maintenance;
  final List<GhServer> servers;
  GithubConfig(this.fingerprint, this.name, this.servers, {this.message = '',
    this.minVersion = '', this.latestVersion = '', this.updateUrl = '', this.epgUrl = '', this.maintenance = false});
}

class ServerConnector {
  final IptvService svc;
  ServerConnector(this.svc);
  Box get _s => Hive.box('settings');
  GithubConfig? lastConfig;

  /// الرابط المحفوظ يدوياً أولاً، ثم الرابط المحقون وقت البناء
  String get configUrl {
    final saved = (_s.get('github_config_url', defaultValue: '') as String).trim();
    return saved.isNotEmpty ? saved : AppConfig.githubConfigUrl;
  }

  static String normalHost(String value) {
    var v = value.trim();
    if (v.isEmpty) throw Exception('أدخل عنوان السيرفر');
    if (!v.startsWith('http://') && !v.startsWith('https://')) v = 'http://$v';
    return v.endsWith('/') ? v.substring(0, v.length - 1) : v;
  }

  static String hashOf(String s) => sha1.convert(utf8.encode(s)).toString();

  /// true إذا كان a أقدم من b (مثال 1.0.0 < 1.1.0)
  static bool versionLess(String a, String b) {
    List<int> p(String v) => v.split('.').map((e) => int.tryParse(e.replaceAll(RegExp(r'\D'), '')) ?? 0).toList();
    final x = p(a), y = p(b);
    for (var i = 0; i < 3; i++) {
      final xi = i < x.length ? x[i] : 0, yi = i < y.length ? y[i] : 0;
      if (xi != yi) return xi < yi;
    }
    return false;
  }

  // ---------- السيرفرات المحفوظة ----------
  List<Map<String, dynamic>> get profiles =>
      (_s.get('profiles', defaultValue: <dynamic>[]) as List)
          .map((e) => Map<String, dynamic>.from(e as Map)).toList();

  String _key(Map p) => '${p['type']}|${p['host'] ?? p['url']}|${p['user'] ?? ''}';

  Future<void> saveProfile(Map<String, dynamic> p) async {
    final list = profiles..removeWhere((e) => _key(e) == _key(p));
    list.insert(0, p);
    await _s.put('profiles', list.take(20).toList());
  }

  Future<void> deleteProfile(int i) async {
    final list = profiles;
    if (i < 0 || i >= list.length) return;
    list.removeAt(i);
    await _s.put('profiles', list);
  }

  Future<List<Channel>> connectProfile(Map p) async {
    if (p['type'] == 'xtream') return xtream('${p['host']}', '${p['user']}', '${p['pass'] ?? ''}');
    return m3uUrl('${p['url']}');
  }

  // ---------- Xtream ----------
  Future<List<Channel>> xtream(String host, String user, String pass) async {
    final h = normalHost(host);
    if (user.trim().isEmpty) throw Exception('أدخل اسم المستخدم');
    final ch = await svc.streams(h, user.trim(), pass, 'live', force: true);
    if (ch.isEmpty) throw Exception('تم الاتصال لكن لم يتم العثور على قنوات');
    await _s.put('xt_host', h);
    await _s.put('xt_user', user.trim());
    await _s.put('xt_pass', pass);
    await _s.put('server_type', 'xtream');
    await _s.put('last_server_name', 'Xtream');
    await _s.delete('epg_url');
    await saveProfile({'type': 'xtream', 'name': h.replaceFirst(RegExp(r'^https?://'), ''),
      'host': h, 'user': user.trim(), 'pass': pass});
    return ch;
  }

  // ---------- M3U ----------
  Future<List<Channel>> m3uUrl(String url) async {
    if (url.trim().isEmpty) throw Exception('أدخل رابط M3U');
    final ch = await svc.loadM3u(url.trim(), force: true);
    if (ch.isEmpty) throw Exception('لم يتم العثور على قنوات في القائمة');
    await _s.put('m3u_url', url.trim());
    await _s.put('server_type', 'm3u_url');
    await _s.put('last_server_name', 'M3U');
    await saveProfile({'type': 'm3u', 'name': 'M3U', 'url': url.trim()});
    return ch;
  }

  Future<List<Channel>> m3uText(String content) async {
    final ch = svc.parseM3u(content);
    if (ch.isEmpty) throw Exception('لم يتم العثور على قنوات في الملف');
    await Hive.box('cache').put('file_channels', ch.map((c) => c.toMap()).toList());
    await _s.put('server_type', 'm3u_file');
    return ch;
  }

  List<Channel> savedFileChannels() {
    final raw = Hive.box('cache').get('file_channels');
    if (raw is! List) return [];
    return raw.map((e) => Channel.fromMap(Map.from(e as Map))).toList();
  }

  /// قطع الاتصال: يوقف التحديث التلقائي ويمسح بيانات السيرفر الحالي
  Future<void> disconnect() async {
    await _s.put('server_type', 'none');
    for (final k in ['xt_host', 'xt_user', 'xt_pass', 'github_fp', 'github_last_sync',
        'github_server_names', 'github_server_index', 'last_server_name', 'epg_url']) {
      await _s.delete(k);
    }
    lastConfig = null;
  }

  // ---------- GitHub (تحديث تلقائي) ----------
  /// يقبل رابط raw أو رابط github.com العادي (blob) أو رابط المستودع فقط،
  /// ويولّد روابط بديلة (main/master + jsDelivr) في حال فشل الرابط الأول
  static List<String> configCandidates(String input) {
    final u = input.trim();
    String? user, repo, branch, path;
    final g = RegExp(r'^https?://github\.com/([^/]+)/([^/?#]+?)(?:\.git)?(?:/(?:blob|raw)/([^/]+)/([^?#]+))?/?(?:[?#].*)?$').firstMatch(u);
    if (g != null) {
      user = g[1]; repo = g[2]; branch = g[3]; path = g[4];
    } else {
      final r = RegExp(r'^https?://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/?#]+)/([^?#]+)').firstMatch(u);
      if (r != null) { user = r[1]; repo = r[2]; branch = r[3]; path = r[4]; }
    }
    if (user == null) return [u];
    final file = path ?? 'xtream_config.json';
    final branches = <String>{if (branch != null) branch, 'main', 'master'}.toList();
    return [
      for (final b in branches) 'https://raw.githubusercontent.com/$user/$repo/$b/$file',
      for (final b in branches) 'https://cdn.jsdelivr.net/gh/$user/$repo@$b/$file',
    ];
  }

  Future<GithubConfig> fetchConfig(String url) async {
    String? body;
    for (final candidate in configCandidates(url)) {
      try {
        final base = Uri.parse(candidate);
        final uri = base.replace(queryParameters: {
          ...base.queryParameters,
          't': '${DateTime.now().millisecondsSinceEpoch}', // كسر كاش CDN
        });
        final res = await http.get(uri, headers: {...kHttpHeaders, 'Cache-Control': 'no-cache'})
            .timeout(const Duration(seconds: 25));
        if (res.statusCode == 200) { body = utf8.decode(res.bodyBytes); break; }
      } catch (_) {/* جرّب الرابط البديل */}
    }
    if (body == null) {
      throw Exception('ملف الإعدادات غير موجود على GitHub — تأكد أن المستودع عام (Public) وأن xtream_config.json '
          'في المجلد الرئيسي، أو الصق رابط الملف الصحيح في الخانة أعلاه');
    }
    final d = jsonDecode(body);
    if (d is! Map) throw Exception('تنسيق JSON غير صحيح');
    if (d['status']?.toString().toLowerCase() != 'active') {
      throw Exception('الإعدادات غير مفعّلة (status ليس active)');
    }
    final servers = <GhServer>[];
    final list = d['xtream_servers'];
    if (list is List) {
      for (final s in list) {
        if (s is! Map) continue;
        final n = s['server_name']?.toString() ?? 'Server ${servers.length + 1}';
        if ('${s['host'] ?? ''}'.isNotEmpty && '${s['username'] ?? ''}'.isNotEmpty) {
          servers.add(GhServer(n, host: normalHost('${s['host']}'),
              user: '${s['username']}', pass: '${s['password'] ?? ''}'));
        } else if ('${s['m3u_url'] ?? ''}'.isNotEmpty) {
          servers.add(GhServer(n, m3u: '${s['m3u_url']}'));
        }
      }
    }
    final top = d['m3u_url']?.toString() ?? '';
    if (top.isNotEmpty) servers.add(GhServer('M3U', m3u: top));
    final maintenance = d['maintenance'] == true;
    if (servers.isEmpty && !maintenance) {
      throw Exception('لا توجد بيانات xtream_servers أو m3u_url في الملف');
    }
    return GithubConfig(hashOf(body), d['server_name']?.toString() ?? 'GitHub', servers,
        message: d['message']?.toString() ?? '',
        minVersion: d['min_version']?.toString() ?? '',
        latestVersion: d['latest_version']?.toString() ?? '',
        updateUrl: d['update_url']?.toString() ?? '',
        epgUrl: d['epg_url']?.toString() ?? '',
        maintenance: maintenance);
  }

  Future<bool> configChanged() async {
    final cfg = await fetchConfig(configUrl);
    return cfg.fingerprint != (_s.get('github_fp') as String?);
  }

  Future<List<Channel>> syncGithub() async {
    final url = configUrl;
    if (url.isEmpty) throw Exception('لا يوجد رابط GitHub');
    GithubConfig cfg;
    try {
      cfg = await fetchConfig(url);
    } catch (e) {
      // بدون إنترنت: استخدم آخر بيانات محفوظة
      final host = (_s.get('xt_host', defaultValue: '') as String);
      final user = (_s.get('xt_user', defaultValue: '') as String);
      if (host.isNotEmpty && user.isNotEmpty) {
        return svc.streams(host, user, _s.get('xt_pass', defaultValue: '') as String, 'live');
      }
      rethrow;
    }
    lastConfig = cfg;
    if (cfg.maintenance) {
      throw Exception(cfg.message.isEmpty ? 'الخدمة في صيانة حالياً' : cfg.message);
    }
    final start = ((_s.get('github_server_index', defaultValue: 0) as int)
        .clamp(0, cfg.servers.length - 1)).toInt();
    // جرّب السيرفر المختار ثم بقية السيرفرات بالترتيب إن فشل
    List<Channel> ch = [];
    GhServer sv = cfg.servers[start];
    Object? lastError;
    for (var k = 0; k < cfg.servers.length; k++) {
      final i = (start + k) % cfg.servers.length;
      final cand = cfg.servers[i];
      try {
        final list = cand.host != null
            ? await svc.streams(cand.host!, cand.user!, cand.pass!, 'live', force: true)
            : await svc.loadM3u(cand.m3u!, force: true);
        if (list.isEmpty) continue;
        ch = list; sv = cand;
        await _s.put('github_server_index', i);
        break;
      } catch (e) {
        lastError = e;
      }
    }
    if (ch.isEmpty && lastError != null) throw lastError;
    if (sv.host != null) {
      await _s.put('xt_host', sv.host);
      await _s.put('xt_user', sv.user);
      await _s.put('xt_pass', sv.pass);
    } else {
      await _s.put('xt_host', '');
    }
    if (ch.isEmpty) throw Exception('تم الاتصال لكن لم يتم العثور على قنوات');
    await _s.put('github_server_names', cfg.servers.map((e) => e.name).toList());
    if (cfg.epgUrl.isNotEmpty) { await _s.put('epg_url', cfg.epgUrl); } else { await _s.delete('epg_url'); }
    await _s.put('server_type', 'github');
    await _s.put('github_fp', cfg.fingerprint);
    await _s.put('github_last_sync', DateTime.now().millisecondsSinceEpoch);
    await _s.put('last_server_name', sv.name);
    return ch;
  }
}
