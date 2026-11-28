import 'dart:convert';
import 'package:hive/hive.dart';

/// مفاتيح الإعدادات التي تدخل في النسخة الاحتياطية (بما فيها الرقابة الأبوية والسيرفرات)
const backupKeys = [
  'lang', 'decoder', 'fit', 'bufferMb', 'prebufferSec', 'liveFormat', 'lite',
  'subSize', 'subColor', 'subBg', 'autoSync', 'player', 'customPackage', 'uiStyle',
  'hidden', 'profiles', 'pin', 'locked', 'github_config_url', 'github_server_index',
  'xt_host', 'xt_user', 'xt_pass', 'server_type', 'last_server_name',
];

/// نسخة احتياطية (المفضلة + الإعدادات + السيرفرات + الرقابة الأبوية) كنص JSON
String exportBackup() {
  final s = Hive.box('settings');
  final fav = Hive.box('favorites');
  return jsonEncode({
    'app': 'ANES TV', 'v': 2, 'at': DateTime.now().toIso8601String(),
    'favorites': fav.values.map((e) => Map<String, dynamic>.from(e as Map)).toList(),
    'settings': {for (final k in backupKeys) if (s.containsKey(k)) k: s.get(k)},
  });
}

/// يرجع عدد المفضلات المستعادة. يرمي استثناء إن كان الملف غير صالح
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
    for (final k in backupKeys) { if (st.containsKey(k)) await s.put(k, st[k]); }
  }
  return n;
}
