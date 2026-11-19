import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import '../config.dart';
import 'iptv_service.dart';

class GithubConfig {
  final String fingerprint, name;
  final String? host, user, pass, m3u;
  GithubConfig(this.fingerprint, this.name, {this.host, this.user, this.pass, this.m3u});
}

class ServerConnector {
  final IptvService svc;
  ServerConnector(this.svc);
  Box get _s => Hive.box('settings');

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
    return ch;
  }

  // ---------- M3U ----------
  Future<List<Channel>> m3uUrl(String url) async {
    if (url.trim().isEmpty) throw Exception('أدخل رابط M3U');
    final ch = await svc.loadM3u(url.trim(), force: true);
    if (ch.isEmpty) throw Exception('لم يتم العثور على قنوات في القائمة');
    await _s.put('m3u_url', url.trim());
    await _s.put('server_type', 'm3u_url');
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

  // ---------- GitHub (تحديث تلقائي) ----------
  Future<GithubConfig> fetchConfig(String url) async {
    final base = Uri.parse(url);
    final uri = base.replace(queryParameters: {
      ...base.queryParameters,
      't': '${DateTime.now().millisecondsSinceEpoch}', // كسر كاش CDN
    });
    final res = await http.get(uri, headers: {'Cache-Control': 'no-cache'})
        .timeout(const Duration(seconds: 25));
    if (res.statusCode != 200) throw Exception('GitHub HTTP ${res.statusCode}');
    final body = utf8.decode(res.bodyBytes);
    final d = jsonDecode(body);
    if (d is! Map) throw Exception('تنسيق JSON غير صحيح');
    if (d['status']?.toString().toLowerCase() != 'active') {
      throw Exception('الإعدادات غير مفعّلة (status ليس active)');
    }
    final fp = sha1.convert(utf8.encode(body)).toString();
    final name = d['server_name']?.toString() ?? 'GitHub';
    final servers = d['xtream_servers'];
    if (servers is List) {
      for (final s in servers) {
        if (s is Map && '${s['host'] ?? ''}'.isNotEmpty && '${s['username'] ?? ''}'.isNotEmpty) {
          return GithubConfig(fp, s['server_name']?.toString() ?? name,
              host: normalHost('${s['host']}'), user: '${s['username']}', pass: '${s['password'] ?? ''}');
        }
      }
    }
    final m3u = d['m3u_url']?.toString() ?? '';
    if (m3u.isNotEmpty) return GithubConfig(fp, name, m3u: m3u);
    throw Exception('لا توجد بيانات xtream_servers أو m3u_url في الملف');
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
    List<Channel> ch;
    if (cfg.host != null) {
      ch = await svc.streams(cfg.host!, cfg.user!, cfg.pass!, 'live', force: true);
      await _s.put('xt_host', cfg.host);
      await _s.put('xt_user', cfg.user);
      await _s.put('xt_pass', cfg.pass);
    } else {
      ch = await svc.loadM3u(cfg.m3u!, force: true);
    }
    if (ch.isEmpty) throw Exception('تم الاتصال لكن لم يتم العثور على قنوات');
    await _s.put('server_type', 'github');
    await _s.put('github_fp', cfg.fingerprint);
    await _s.put('github_last_sync', DateTime.now().millisecondsSinceEpoch);
    await _s.put('last_server_name', cfg.name);
    return ch;
  }
}
