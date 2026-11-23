import 'dart:convert';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;

/// يترجم أسطر الترجمة (نصية فقط) عبر الإنترنت ويحفظ الأسطر المترجمة لإعادة استخدامها بدون إنترنت
class SubtitleTranslator {
  final String target;
  SubtitleTranslator({this.target = 'ar'}) { _load(); }

  final Map<String, String> _cache = {};
  int _dirty = 0;
  Box get _box => Hive.box('cache');
  String get _key => 'sub_tr_$target';
  static const _ua = {'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36'};

  void _load() {
    try {
      final m = _box.get(_key);
      if (m is Map) m.forEach((k, v) => _cache['$k'] = '$v');
    } catch (_) {}
  }

  void _persist() {
    try {
      if (_cache.length > 5000) _cache.clear();
      _box.put(_key, Map<String, String>.from(_cache));
    } catch (_) {}
    _dirty = 0;
  }

  void flush() { if (_dirty > 0) _persist(); }

  /// يزيل وسوم HTML/ASS ويحوّل الأسطر المتعددة إلى سطر واحد
  static String clean(String s) => s
      .replaceAll(RegExp(r'<[^>]*>|\{[^}]*\}'), '')
      .replaceAll(RegExp(r'\s*\n\s*'), ' ')
      .trim();

  Future<String?> translate(String raw) async {
    final text = clean(raw);
    if (text.isEmpty) return null;
    final hit = _cache[text];
    if (hit != null) return hit;
    final out = await _google(text) ?? await _myMemory(text);
    if (out != null && out.trim().isNotEmpty) {
      _cache[text] = out;
      if (++_dirty >= 15) _persist();
    }
    return out;
  }

  Future<String?> _google(String text) async {
    try {
      final uri = Uri.https('translate.googleapis.com', '/translate_a/single',
          {'client': 'gtx', 'sl': 'auto', 'tl': target, 'dt': 't', 'q': text});
      final res = await http.get(uri, headers: _ua).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final d = jsonDecode(utf8.decode(res.bodyBytes));
      if (d is! List || d.isEmpty || d[0] is! List) return null;
      final sb = StringBuffer();
      for (final seg in d[0] as List) {
        if (seg is List && seg.isNotEmpty && seg[0] != null) sb.write(seg[0]);
      }
      final s = sb.toString().trim();
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _myMemory(String text) async {
    try {
      final uri = Uri.https('api.mymemory.translated.net', '/get', {'q': text, 'langpair': 'en|$target'});
      final res = await http.get(uri, headers: _ua).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final d = jsonDecode(utf8.decode(res.bodyBytes));
      final s = (d is Map && d['responseData'] is Map) ? '${d['responseData']['translatedText'] ?? ''}'.trim() : '';
      if (s.isEmpty || s.toUpperCase().contains('MYMEMORY WARNING')) return null;
      return s;
    } catch (_) {
      return null;
    }
  }
}
