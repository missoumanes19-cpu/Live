import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'iptv_service.dart';
import 'subtitle_file.dart';

/// ما نبحث عنه: عنوان نظيف (+ موسم/حلقة للمسلسلات)
class SubQuery {
  final String title;
  final int? year, season, episode;
  const SubQuery(this.title, {this.year, this.season, this.episode});
  bool get isEpisode => season != null;

  static SubQuery fromChannel(Channel c) {
    var name = c.name;
    final year = int.tryParse(RegExp(r'\b((?:19|20)\d{2})\b').firstMatch(name)?.group(1) ?? '');
    int? season, episode;
    final se = RegExp(r'[Ss](\d{1,2})\s*[Ee](\d{1,3})').firstMatch(name);
    if (se != null) {
      season = int.parse(se.group(1)!);
      episode = int.parse(se.group(2)!);
      name = name.substring(0, se.start); // اسم المسلسل قبل SxxExx
    } else if (c.group.contains(RegExp(r'\d'))) {
      season = int.tryParse(RegExp(r'(\d+)').firstMatch(c.group)?.group(1) ?? '');
      final ep = RegExp(r'(?:episode|ep\.?|e|حلقة|الحلقة)\s*0*(\d{1,3})', caseSensitive: false).firstMatch(name);
      episode = int.tryParse(ep?.group(1) ?? '');
      if (episode != null && name.contains(' - ')) name = name.split(' - ').first;
    }
    return SubQuery(_clean(name), year: year, season: season, episode: episode);
  }

  static String _clean(String s) {
    var t = s
        .replaceAll(RegExp(r'\[[^\]]*\]|\([^)]*\)|\{[^}]*\}'), ' ')
        .replaceAll(RegExp(r'^\s*[A-Za-z]{2,3}\s*[-:|]\s*'), '') // بادئة لغة مثل "EN - "
        .replaceAll(RegExp(r'\b(?:4k|uhd|fhd|hdr|2160p|1080p|720p|480p|bluray|web-?dl|webrip|hdrip|x264|x265|hevc|multi|dubbed)\b',
            caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\b(?:19|20)\d{2}\b'), ' ')
        .replaceAll(RegExp(r'[._|]+'), ' ')
        .replaceAll(RegExp(r'\s*-\s*$'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return t;
  }
}

class FoundSubtitle {
  final String lang; // ar | en
  final String srt;  // نص SRT جاهز
  FoundSubtitle(this.lang, this.srt);
}

/// يبحث عن ملف الترجمة ويحمّله. المزوّدات تُجرَّب بالترتيب ويفشل كل واحد بصمت:
///  1) OpenSubtitles الرسمي (api.opensubtitles.com) إن أدخل المستخدم المفتاح + الحساب في الإعدادات
///  2) واجهة OpenSubtitles القديمة (rest.opensubtitles.org) بدون مفتاح — قد تتوقف في أي وقت
class SubtitleFetcher {
  static const _ua = 'ANESTV v1.3';
  static const _lang3 = {'ar': 'ara', 'en': 'eng', 'fr': 'fre', 'es': 'spa', 'tr': 'tur', 'de': 'ger', 'ru': 'rus',
    'fa': 'per', 'pt': 'por', 'it': 'ita', 'any': 'all'}; // any = أي لغة
  final http.Client _c = http.Client();
  Box get _s => Hive.box('settings');
  static String? _token, _tokenBase;

  Future<FoundSubtitle?> find(SubQuery q, String lang) async {
    if (q.title.isEmpty) return null;
    if (q.isEpisode && q.episode == null) return null; // لا نخمّن حلقة (ترجمة خاطئة أسوأ من لا شيء)
    final hasKey = (_s.get('os_api_key', defaultValue: '') as String).trim().isNotEmpty;
    final order = hasKey ? [_official, _legacy] : [_legacy, _official];
    for (final p in order) {
      try {
        final r = await p(q, lang);
        if (r != null) return r;
      } catch (_) {}
    }
    return null;
  }

  /// يتحقق أن النص ترجمة حقيقية ويحوّله إلى SRT موحّد
  FoundSubtitle? _accept(String lang, String raw, String ext) {
    final cues = parseSubtitle(raw, ext);
    if (cues.length < 30) return null;
    return FoundSubtitle(lang, toSrt(cues));
  }

  // ---------- OpenSubtitles الرسمي ----------
  Future<FoundSubtitle?> _official(SubQuery q, String lang) async {
    final key = (_s.get('os_api_key', defaultValue: '') as String).trim();
    final user = (_s.get('os_user', defaultValue: '') as String).trim();
    final pass = (_s.get('os_pass', defaultValue: '') as String).trim();
    if (key.isEmpty || user.isEmpty || pass.isEmpty) return null;
    final h = {'Api-Key': key, 'User-Agent': _ua, 'Content-Type': 'application/json', 'Accept': 'application/json'};
    if (_token == null) {
      final r = await _c.post(Uri.parse('https://api.opensubtitles.com/api/v1/login'), headers: h,
          body: jsonEncode({'username': user, 'password': pass})).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      final d = jsonDecode(utf8.decode(r.bodyBytes));
      _token = '${d['token'] ?? ''}';
      final b = '${d['base_url'] ?? 'api.opensubtitles.com'}';
      _tokenBase = b.startsWith('http') ? b : 'https://$b';
      if (_token!.isEmpty) { _token = null; return null; }
    }
    final base = _tokenBase ?? 'https://api.opensubtitles.com';
    final auth = {...h, 'Authorization': 'Bearer $_token'};
    final params = {
      'query': q.title, if (lang != 'any') 'languages': lang, 'order_by': 'download_count', 'order_direction': 'desc',
      'type': q.isEpisode ? 'episode' : 'movie',
      if (q.isEpisode) 'season_number': '${q.season}',
      if (q.isEpisode) 'episode_number': '${q.episode}',
      if (!q.isEpisode && q.year != null) 'year': '${q.year}',
    };
    final s = await _c.get(Uri.parse('$base/api/v1/subtitles').replace(queryParameters: params), headers: auth)
        .timeout(const Duration(seconds: 20));
    if (s.statusCode == 401) { _token = null; return null; }
    if (s.statusCode != 200) return null;
    final data = (jsonDecode(utf8.decode(s.bodyBytes))['data'] as List?) ?? const [];
    for (final item in data.take(3)) {
      final files = (item['attributes']?['files'] as List?) ?? const [];
      if (files.isEmpty) continue;
      final d = await _c.post(Uri.parse('$base/api/v1/download'), headers: auth,
          body: jsonEncode({'file_id': files.first['file_id'], 'sub_format': 'srt'}))
          .timeout(const Duration(seconds: 20));
      if (d.statusCode != 200) return null; // غالباً انتهت حصة التحميل اليومية
      final link = '${jsonDecode(utf8.decode(d.bodyBytes))['link'] ?? ''}';
      if (link.isEmpty) continue;
      final f = await _c.get(Uri.parse(link), headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 30));
      if (f.statusCode != 200) continue;
      final ok = _accept(lang, decodeSubtitle(f.bodyBytes), 'srt');
      if (ok != null) return ok;
    }
    return null;
  }

  // ---------- واجهة OpenSubtitles القديمة ----------
  Future<FoundSubtitle?> _legacy(SubQuery q, String lang) async {
    final name = Uri.encodeComponent(q.title.toLowerCase());
    final path = q.isEpisode
        ? 'episode-${q.episode}/query-$name/season-${q.season}/sublanguageid-${_lang3[lang] ?? 'all'}'
        : 'query-$name/sublanguageid-${_lang3[lang] ?? 'all'}';
    final r = await _c.get(Uri.parse('https://rest.opensubtitles.org/search/$path'),
        headers: {'User-Agent': 'TemporaryUserAgent', 'X-User-Agent': 'TemporaryUserAgent'})
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) return null;
    final list = jsonDecode(utf8.decode(r.bodyBytes));
    if (list is! List || list.isEmpty) return null;
    final sorted = List<Map>.from(list.whereType<Map>().where((e) => '${e['SubHearingImpaired']}' != '1'))
      ..sort((a, b) => (int.tryParse('${b['SubDownloadsCnt']}') ?? 0).compareTo(int.tryParse('${a['SubDownloadsCnt']}') ?? 0));
    for (final e in sorted.take(3)) {
      final link = '${e['SubDownloadLink'] ?? ''}';
      if (link.isEmpty) continue;
      final f = await _c.get(Uri.parse(link), headers: {'User-Agent': 'TemporaryUserAgent'})
          .timeout(const Duration(seconds: 30));
      if (f.statusCode != 200) continue;
      final bytes = (f.bodyBytes.length > 2 && f.bodyBytes[0] == 0x1f && f.bodyBytes[1] == 0x8b)
          ? Uint8List.fromList(gzip.decode(f.bodyBytes)) : f.bodyBytes;
      final fmt = '${e['SubFormat'] ?? 'srt'}'.toLowerCase();
      final ok = _accept(lang, decodeSubtitle(bytes), fmt);
      if (ok != null) return ok;
    }
    return null;
  }

  void close() => _c.close();
}
