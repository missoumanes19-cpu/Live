import 'dart:convert';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'errors.dart';

/// مكان (مدينة) على Radio Garden
class RadioPlace {
  final String id, title, country;
  final int size; // عدد المحطات
  const RadioPlace(this.id, this.title, this.country, this.size);
}

/// محطة راديو
class RadioStation {
  final String id, title, subtitle;
  const RadioStation(this.id, this.title, this.subtitle);
  String get streamUrl => RadioGardenService.streamUrl(id);
}

/// عميل Radio Garden (واجهة غير رسمية وقد تتغيّر أو تتوقف دون إشعار).
/// المحطات وحقوقها تعود لأصحابها وRadio Garden BV.
class RadioGardenService {
  static const _base = 'https://radio.garden/api';
  static const _hdr = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Mobile Safari/537.36',
    'Accept': 'application/json',
  };
  final http.Client _c = http.Client();
  Box get _cache => Hive.box('cache');

  /// الرابط الذي يحوّل إلى البث المباشر للمحطة
  static String streamUrl(String id) => '$_base/ara/content/listen/$id/channel.mp3';

  Future<dynamic> _get(String path) async {
    final r = await withRetry(() => _c.get(Uri.parse('$_base$path'), headers: _hdr).timeout(const Duration(seconds: 30)));
    if (r.statusCode != 200) throw Exception('Radio Garden HTTP ${r.statusCode}');
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  /// كل الأماكن (تُخزَّن 3 أيام لتسريع الفتح)
  Future<List<RadioPlace>> places({bool force = false}) async {
    final c = _cache.get('rg_places');
    final now = DateTime.now().millisecondsSinceEpoch;
    List rows;
    if (!force && c is Map && c['rows'] is List && now - (c['ts'] as int? ?? 0) < 3 * 86400000) {
      rows = c['rows'] as List;
    } else {
      final d = await _get('/ara/content/places');
      // نتجنّب ?[ داخل شرط ثلاثي: المحلّل يخلطها مع بداية شرط جديد
      dynamic raw;
      if (d is Map) {
        final data = d['data'];
        if (data is Map) raw = data['list'];
      }
      final items = raw is List ? raw : const [];
      rows = [
        for (final e in items)
          if (e is Map && e['id'] != null) ['${e['id']}', '${e['title'] ?? ''}', '${e['country'] ?? ''}', (e['size'] as num?)?.toInt() ?? 0]
      ];
      if (rows.isEmpty) throw Exception('استجابة غير متوقعة من Radio Garden');
      _cache.put('rg_places', {'ts': now, 'rows': rows});
    }
    return [for (final r in rows) RadioPlace(r[0] as String, r[1] as String, r[2] as String, r[3] as int)];
  }

  Future<List<RadioStation>> channels(String placeId) async =>
      _extract(await _get('/ara/content/page/$placeId/channels'));

  Future<List<RadioStation>> search(String q) async =>
      _extract(await _get('/search?q=${Uri.encodeQueryComponent(q)}'));

  /// يستخرج المحطات من أي شكل للرد: عنصر رابطه يبدأ بـ /listen/<اسم>/<المعرّف>
  List<RadioStation> _extract(dynamic data) {
    final out = <String, RadioStation>{};
    void visit(dynamic n) {
      if (n is List) {
        for (final e in n) { visit(e); }
      } else if (n is Map) {
        final pg = n['page'] is Map ? n['page'] as Map : n;
        final url = '${pg['url'] ?? ''}';
        if (url.startsWith('/listen/')) {
          final id = url.split('/').where((s) => s.isNotEmpty).last;
          final place = pg['place'] is Map ? '${(pg['place'] as Map)['title'] ?? ''}' : '';
          final sub = '${pg['subtitle'] ?? place}';
          out.putIfAbsent(id, () => RadioStation(id, '${pg['title'] ?? id}', sub));
        } else {
          for (final v in n.values) {
            if (v is List || v is Map) visit(v);
          }
        }
      }
    }
    visit(data);
    return out.values.toList();
  }
}

/// أسماء الدول العربية (تظهر أولاً وبالعربية)
const Map<String, String> kArabCountries = {
  'Algeria': 'الجزائر', 'Morocco': 'المغرب', 'Tunisia': 'تونس', 'Libya': 'ليبيا', 'Egypt': 'مصر',
  'Saudi Arabia': 'السعودية', 'United Arab Emirates': 'الإمارات', 'Qatar': 'قطر', 'Kuwait': 'الكويت',
  'Bahrain': 'البحرين', 'Oman': 'عُمان', 'Yemen': 'اليمن', 'Iraq': 'العراق', 'Syria': 'سوريا',
  'Lebanon': 'لبنان', 'Jordan': 'الأردن', 'Palestine': 'فلسطين', 'Sudan': 'السودان',
  'Mauritania': 'موريتانيا', 'Somalia': 'الصومال', 'Djibouti': 'جيبوتي', 'Comoros': 'جزر القمر',
};
