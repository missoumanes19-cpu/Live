import 'dart:io' show Platform;
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../screens/player_screen.dart';
import '../state/app_settings.dart';
import 'iptv_service.dart';

/// حزم MX Player (النسخة المدفوعة ثم المجانية). مصرّح بها في <queries> عبر tool/patch_android.py
const _mxPackages = ['com.mxtech.videoplayer.pro', 'com.mxtech.videoplayer.ad'];

/// YTV Pro (Google Play: com.ytv.pronew)
const _ytvPackage = 'com.ytv.pronew';

AndroidIntent _viewIntent(Channel c, {String? package}) => AndroidIntent(
      action: 'action_view',
      data: c.url,
      type: 'video/*',
      package: package,
      arguments: <String, dynamic>{'title': c.name},
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    );

/// يفتح الرابط في مشغّل خارجي. mode: ytv | mx | chooser | custom
/// يرجع false إذا تعذّر الفتح (غير مثبّت، أو رابط ملف محلي لا يمكن مشاركته).
Future<bool> launchExternal(Channel c, {required String mode, String customPackage = ''}) async {
  if (!Platform.isAndroid) return false;
  // file:// أو مسار محلي لا يمكن تمريره لتطبيق آخر (FileUriExposedException)
  if (!c.url.toLowerCase().startsWith('http')) return false;
  try {
    if (mode == 'chooser') {
      await _viewIntent(c).launchChooser(c.name);
      return true;
    }
    if (mode == 'ytv') {
      final intent = _viewIntent(c, package: _ytvPackage);
      if (await intent.canResolveActivity() != true) return false; // غير مثبّت
      await intent.launch();
      return true;
    }
    if (mode == 'custom') {
      final pkg = customPackage.trim();
      if (pkg.isEmpty) return false;
      await _viewIntent(c, package: pkg).launch();
      return true;
    }
    for (final pkg in _mxPackages) {
      final intent = _viewIntent(c, package: pkg);
      if (await intent.canResolveActivity() == true) {
        await intent.launch();
        return true;
      }
    }
    return false;
  } catch (_) {
    return false;
  }
}

/// نقطة الدخول الوحيدة لتشغيل أي قناة/فيلم/حلقة: حسب إعداد «المشغّل» (internal | ytv | mx | chooser | custom).
/// [player] يتجاوز الإعداد (مثلاً 'mx' من قائمة المشغّل الداخلي).
/// يرجع true إذا فُتح مشغّل (داخلي أو خارجي).
Future<bool> openPlayer(
  BuildContext context,
  Channel c, {
  required bool live,
  List<Channel> playlist = const <Channel>[],
  String? player,
  bool fallbackToInternal = true,
}) async {
  // نلتقط كل ما يحتاج context قبل أي await
  final settings = context.read<AppSettings>();
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  var mode = player ?? settings.player;
  // YTV Pro للقنوات المباشرة فقط: الأفلام والمسلسلات والحلقات تعمل دائماً بالمشغّل الداخلي
  if (mode == 'ytv' && !live) mode = 'internal';

  if (mode != 'internal') {
    final ok = await launchExternal(c, mode: mode, customPackage: settings.customPackage);
    if (ok) return true;
    messenger.showSnackBar(SnackBar(
      content: Text(t(fallbackToInternal
          ? 'المشغّل الخارجي غير متاح، سيتم استخدام المشغّل الداخلي'
          : 'المشغّل الخارجي غير متاح')),
    ));
    if (!fallbackToInternal) return false;
  }

  await navigator.push(MaterialPageRoute(
    builder: (_) => PlayerScreen(channel: c, isLive: live, playlist: playlist),
  ));
  return true;
}
