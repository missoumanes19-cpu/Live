import 'dart:convert';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;

class Channel {
  final String id, name, group, logo, url;
  final String? epgId;
  Channel({required this.id, required this.name, required this.group,
      required this.logo, required this.url, this.epgId});
  Map<String, dynamic> toMap() => {'id': id, 'name': name, 'group': group,
      'logo': logo, 'url': url, 'epgId': epgId};
  factory Channel.fromMap(Map m) => Channel(id: m['id'], name: m['name'],
      group: m['group'], logo: m['logo'], url: m['url'], epgId: m['epgId']);
}

class Category {
  final String id, name;
  Category(this.id, this.name);
}

/// كثير من سيرفرات Xtream ترفض User-Agent الافتراضي لـ Dart، لذلك نستخدم هوية مشغّل معروف
const Map<String, String> kHttpHeaders = {
  'User-Agent': 'VLC/3.0.20 LibVLC/3.0.20',
  'Accept': '*/*',
};

class IptvService {
  final http.Client _client = http.Client();
  static const _ttl = Duration(hours: 6);
  late final Box _cache = Hive.box('cache');

  // ---------- M3U ----------
  static final _attr = RegExp(r'([\w-]+)="([^"]*)"');

  List<Channel> parseM3u(String body) {
    final out = <Channel>[];
    final lines = const LineSplitter().convert(body);
    Map<String, String>? attrs;
    String name = '';
    for (final raw in lines) {
      final l = raw.trim();
      if (l.startsWith('#EXTINF')) {
        attrs = {for (final m in _attr.allMatches(l)) m.group(1)!: m.group(2)!};
        name = l.contains(',') ? l.substring(l.lastIndexOf(',') + 1).trim() : '';
      } else if (l.isNotEmpty && !l.startsWith('#') && attrs != null) {
        out.add(Channel(
          id: attrs['tvg-id']?.isNotEmpty == true ? attrs['tvg-id']! : l.hashCode.toString(),
          name: attrs['tvg-name']?.isNotEmpty == true ? attrs['tvg-name']! : name,
          group: attrs['group-title'] ?? 'Other',
          logo: attrs['tvg-logo'] ?? '',
          url: l,
          epgId: attrs['tvg-id'],
        ));
        attrs = null;
      }
    }
    return out;
  }

  Future<List<Channel>> loadM3u(String url, {bool force = false}) async {
    final key = 'm3u_$url';
    final cached = _readCache(key);
    if (cached != null && !force) {
      return (cached as List).map((e) => Channel.fromMap(e)).toList();
    }
    final res = await _client.get(Uri.parse(url), headers: kHttpHeaders).timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) throw Exception('M3U HTTP ${res.statusCode}');
    final list = parseM3u(utf8.decode(res.bodyBytes, allowMalformed: true));
    _writeCache(key, list.map((c) => c.toMap()).toList());
    return list;
  }

  // ---------- Xtream Codes ----------
  Future<dynamic> _xt(String host, String u, String p, String action,
      {Map<String, String> extra = const {}, bool force = false}) async {
    final uri = Uri.parse('$host/player_api.php').replace(queryParameters:
        {'username': u, 'password': p, if (action.isNotEmpty) 'action': action, ...extra});
    final key = 'xt_${uri.toString()}';
    final cached = _readCache(key);
    if (cached != null && !force) return cached;
    final res = await _client.get(uri, headers: kHttpHeaders).timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) throw Exception('Xtream HTTP ${res.statusCode}');
    final text = utf8.decode(res.bodyBytes, allowMalformed: true).trim();
    if (text.isEmpty) throw Exception('السيرفر لم يرجع أي بيانات (تحقق من الرابط وبيانات الدخول)');
    dynamic data;
    try {
      data = jsonDecode(text);
    } catch (_) {
      throw Exception('استجابة غير صالحة من السيرفر (ليس Xtream API؟) — تحقق من العنوان والمنفذ');
    }
    if (data is Map && data['user_info'] is Map && '${data['user_info']['auth']}' == '0') {
      throw Exception('بيانات الدخول خاطئة أو انتهى الاشتراك');
    }
    if (action.startsWith('get_') && action != 'get_series_info' && action != 'get_short_epg' && data is! List) {
      throw Exception('استجابة غير متوقعة من السيرفر — تحقق من اسم المستخدم وكلمة المرور');
    }
    _writeCache(key, data);
    return data;
  }

  // kind: live | vod | series
  Future<List<Category>> categories(String host, String u, String p, String kind, {bool force = false}) async {
    final act = {'live': 'get_live_categories', 'vod': 'get_vod_categories',
        'series': 'get_series_categories'}[kind]!;
    final d = await _xt(host, u, p, act, force: force) as List;
    return d.map((e) => Category('${e['category_id']}', '${e['category_name']}')).toList();
  }

  Future<List<Channel>> streams(String host, String u, String p, String kind,
      {String? categoryId, bool force = false}) async {
    final act = {'live': 'get_live_streams', 'vod': 'get_vod_streams',
        'series': 'get_series'}[kind]!;
    final d = await _xt(host, u, p, act,
        extra: {if (categoryId != null) 'category_id': categoryId}, force: force) as List;
    List<Category> categoryList = const [];
    try {
      categoryList = await categories(host, u, p, kind, force: force);
    } catch (_) {/* التصنيفات اختيارية: لا نفشل الاتصال بسببها */}
    final categoryNames = {for (final c in categoryList) c.id: c.name};
    return d.map((e) {
      final id = '${e['stream_id'] ?? e['series_id']}';
      final ext = e['container_extension'] ?? (kind == 'vod' ? 'mp4' : 'ts');
      final url = kind == 'live'
          ? '$host/live/$u/$p/$id.${e['container_extension'] ?? 'ts'}'
          : kind == 'vod' ? '$host/movie/$u/$p/$id.$ext' : '';
      final categoryIdValue = '${e['category_id'] ?? ''}';
      return Channel(id: id, name: '${e['name']}', group: categoryNames[categoryIdValue] ?? 'غير مصنف',
          logo: '${e['stream_icon'] ?? e['cover'] ?? ''}', url: url,
          epgId: e['epg_channel_id']?.toString());
    }).toList();
  }

  Future<Map<String, dynamic>> seriesInfo(String host, String u, String p, String id) async =>
      Map<String, dynamic>.from(await _xt(host, u, p, 'get_series_info', extra: {'series_id': id}));

  Future<List<Channel>> seriesEpisodes(String host, String u, String p, Channel series) async {
    final info = await seriesInfo(host, u, p, series.id);
    final raw = info['episodes'];
    if (raw is! Map) return [];
    final result = <Channel>[];
    raw.forEach((season, episodes) {
      if (episodes is! List) return;
      for (final item in episodes) {
        if (item is! Map) continue;
        final id = '${item['id'] ?? ''}';
        if (id.isEmpty) continue;
        final ext = '${item['container_extension'] ?? 'mp4'}';
        final title = '${item['title'] ?? item['name'] ?? 'Episode $id'}';
        result.add(Channel(
          id: id,
          name: title,
          group: 'الموسم $season',
          logo: '${item['info'] is Map ? (item['info']['movie_image'] ?? '') : ''}',
          url: '$host/series/$u/$p/$id.$ext',
        ));
      }
    });
    return result;
  }

  Future<List<dynamic>> shortEpg(String host, String u, String p, String streamId) async {
    final d = await _xt(host, u, p, 'get_short_epg',
        extra: {'stream_id': streamId, 'limit': '4'}, force: true);
    return (d['epg_listings'] as List?) ?? [];
  }

  String xmltvUrl(String host, String u, String p) => '$host/xmltv.php?username=$u&password=$p';

  Future<Map<String, dynamic>> accountInfo(String host, String u, String p) async {
    final uri = Uri.parse('$host/player_api.php').replace(queryParameters: {'username': u, 'password': p});
    final sw = Stopwatch()..start();
    final res = await _client.get(uri, headers: kHttpHeaders).timeout(const Duration(seconds: 20));
    sw.stop();
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final d = Map<String, dynamic>.from(jsonDecode(utf8.decode(res.bodyBytes)) as Map);
    d['_ms'] = sw.elapsedMilliseconds;
    return d;
  }

  // ---------- Cache ----------
  dynamic _readCache(String key) {
    final e = _cache.get(key);
    if (e == null) return null;
    final ts = DateTime.fromMillisecondsSinceEpoch(e['ts']);
    if (DateTime.now().difference(ts) > _ttl) return null;
    return e['data'];
  }

  void _writeCache(String key, dynamic data) =>
      _cache.put(key, {'ts': DateTime.now().millisecondsSinceEpoch, 'data': data});
}
