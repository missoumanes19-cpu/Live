import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../screens/player_screen.dart';
import '../state/app_settings.dart';
import 'iptv_service.dart';

enum _Ext { launched, copied, notInstalled }

/// هل التطبيق مثبّت؟ (يعمل لأن الحزم مصرّح بها في <queries> داخل الـ manifest)
Future<bool> _installed(String pkg) async {
  try {
    return await AndroidIntent(action: 'android.intent.action.MAIN', package: pkg,
        category: 'android.intent.category.LAUNCHER').canResolveActivity() == true;
  } catch (_) {
    return false;
  }
}

Future<_Ext> _launchExternal(AppSettings s, Channel c) async {
  final List<String> pkgs;
  switch (s.player) {
    case 'mx': pkgs = ['com.mxtech.videoplayer.ad', 'com.mxtech.videoplayer.pro']; break;
    case 'custom': pkgs = s.customPackage.isEmpty ? <String>[] : [s.customPackage]; break;
    default: pkgs = <String>[];
  }
  final mime = c.url.toLowerCase().contains('.m3u8') ? 'application/x-mpegURL' : 'video/*';

  // اختيار تطبيق من النظام (أو لا حزمة محددة)
  if (pkgs.isEmpty) {
    try {
      await AndroidIntent(action: 'action_view', data: c.url, type: mime).launchChooser(t('فتح بواسطة'));
      return _Ext.launched;
    } catch (_) {
      return _Ext.notInstalled;
    }
  }

  for (final pkg in pkgs) {
    if (!await _installed(pkg)) continue;
    try {
      // 1) فتح الرابط مباشرة (بنوع الملف ثم بدونه)
      for (final type in <String?>[mime, null]) {
        final view = AndroidIntent(action: 'action_view', data: c.url, type: type, package: pkg,
          arguments: <String, dynamic>{'title': c.name, 'secure_uri': true});
        if (await view.canResolveActivity() == true) { await view.launch(); return _Ext.launched; }
      }
      // 2) مشاركة الرابط كنص (كثير من المشغّلات الخارجية تستقبله هكذا)
      final send = AndroidIntent(action: 'action_send', type: 'text/plain', package: pkg,
        arguments: <String, dynamic>{'android.intent.extra.TEXT': c.url, 'android.intent.extra.SUBJECT': c.name});
      if (await send.canResolveActivity() == true) { await send.launch(); return _Ext.launched; }
      // 3) آخر حل: انسخ الرابط وافتح التطبيق ليلصقه المستخدم
      await Clipboard.setData(ClipboardData(text: c.url));
      await AndroidIntent(action: 'android.intent.action.MAIN', package: pkg,
        category: 'android.intent.category.LAUNCHER').launch();
      return _Ext.copied;
    } catch (_) {/* جرّب الحزمة التالية */}
  }
  return _Ext.notInstalled;
}

/// يفتح القناة بالمشغّل المختار في الإعدادات (داخلي أو MX أو تطبيق آخر)
Future<void> openPlayer(BuildContext context, Channel c,
    {bool live = true, List<Channel> playlist = const <Channel>[]}) async {
  final s = context.read<AppSettings>();
  if (s.player != 'internal') {
    final r = await _launchExternal(s, c);
    if (!context.mounted) return;
    if (r == _Ext.launched) return;
    if (r == _Ext.copied) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('تم نسخ الرابط. الصقه داخل المشغّل الخارجي لتشغيله'))));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t('المشغّل الخارجي غير مثبّت، سيُستخدم المشغّل الداخلي'))));
  }
  if (!context.mounted) return;
  await Navigator.push(context, MaterialPageRoute(
    builder: (_) => PlayerScreen(channel: c, isLive: live, playlist: playlist)));
}
