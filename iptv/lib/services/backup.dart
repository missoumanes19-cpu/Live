import 'dart:convert';
import 'package:hive/hive.dart';

const _keys = ['lang', 'decoder', 'fit', 'bufferMb', 'prebufferSec', 'subSize', 'subColor', 'subBg', 'autoSync', 'player', 'customPackage', 'uiStyle', 'hidden', 'profiles'];

/// نسخة احتياطية (المفضلة + الإعدادات + السيرفرات المحفوظة) كنص JSON
String exportBackup() {
  final s = Hive.box('settings');
  final fav = Hive.box('favorites');
  return jsonEncode({
    'app': 'ANES TV', 'v': 1,
    'favorites': fav.values.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
    'settings': {for (final k in _keys) if (s.containsKey(k)) k: s.get(k)},
  });
}

Future<int> importBackup(String text) async {
  final d = jsonDecode(text);
  if (d is! Map || d['app'] != 'ANES TV') throw Exception('ملف النسخ الاحتياطي غير صالح');
  var n = 0;
  final fav = Hive.box('favorites');
  for (final e in (d['favorites'] as List? ?? const [])) {
    final m = Map<String, dynamic>.from(e as Map);
    await fav.put(m['id'], m);
    n++;
  }
  final s = Hive.box('settings');
  final st = d['settings'];
  if (st is Map) {
    for (final k in _keys) { if (st.containsKey(k)) await s.put(k, st[k]); }
  }
  return n;
}
