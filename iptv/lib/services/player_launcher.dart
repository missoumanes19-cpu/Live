import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../screens/player_screen.dart';
import '../state/app_settings.dart';
import 'iptv_service.dart';

Future<bool> _launchExternal(AppSettings s, Channel c) async {
  final List<String> pkgs;
  switch (s.player) {
    case 'mx': pkgs = ['com.mxtech.videoplayer.ad', 'com.mxtech.videoplayer.pro']; break;
    case 'ytv': pkgs = ['com.ytv.pronew', 'com.ytv.pro', 'com.ytvplayer']; break;
    case 'custom': pkgs = s.customPackage.isEmpty ? <String>[] : [s.customPackage]; break;
    default: pkgs = <String>[];
  }
  final mime = c.url.toLowerCase().contains('.m3u8') ? 'application/x-mpegURL' : 'video/*';
  try {
    for (final pkg in pkgs) {
      try {
        final intent = AndroidIntent(action: 'action_view', data: c.url, type: mime, package: pkg,
          arguments: <String, dynamic>{'title': c.name, 'secure_uri': true});
        if (await intent.canResolveActivity() == true) {
          await intent.launch();
          return true;
        }
      } catch (_) {/* غير مثبّت أو لا يستقبل الرابط: جرّب التالي */}
    }
    // الحزمة غير متاحة (أو اختيار تطبيق): افتح قائمة اختيار التطبيقات
    await AndroidIntent(action: 'action_view', data: c.url, type: mime)
        .launchChooser(t('فتح بواسطة'));
    return true;
  } catch (_) {}
  return false;
}

/// يفتح القناة بالمشغّل المختار في الإعدادات (داخلي أو MX أو YTV أو تطبيق آخر)
Future<void> openPlayer(BuildContext context, Channel c,
    {bool live = true, List<Channel> playlist = const <Channel>[]}) async {
  final s = context.read<AppSettings>();
  if (s.player != 'internal') {
    if (await _launchExternal(s, c)) return;
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t('المشغّل الخارجي غير مثبّت، سيُستخدم المشغّل الداخلي'))));
  }
  if (!context.mounted) return;
  await Navigator.push(context, MaterialPageRoute(
    builder: (_) => PlayerScreen(channel: c, isLive: live, playlist: playlist)));
}
