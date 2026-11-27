import 'dart:io' show Platform;
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../screens/exo_player_screen.dart';
import '../screens/player_screen.dart';
import '../screens/web_player_screen.dart';
import '../state/app_settings.dart';
import 'iptv_service.dart';

/// حزم MX Player (النسخة المدفوعة ثم المجانية). مصرّح بها في <queries> عبر tool/patch_android.py
const _mxPackages = ['com.mxtech.videoplayer.pro', 'com.mxtech.videoplayer.ad'];

/// YTV Pro (Google Play: com.ytv.pronew) والنشاط الرئيسي له
const _ytvPackage = 'com.ytv.pronew';
const _ytvActivity = 'dev.google.ytvplayer.ui.MainActivity';

/// أنواع MIME نجرّبها بالترتيب: بعض المشغّلات تسجّل فلتر HLS فقط أو بلا نوع
const _videoTypes = <String?>['video/*', 'application/x-mpegURL', 'application/vnd.apple.mpegurl', null];

AndroidIntent _viewIntent(Channel c, {String? package, String? component, String? type = 'video/*'}) => AndroidIntent(
      action: 'action_view',
      data: c.url,
      type: type,
      package: package,
      componentName: component,
      arguments: <String, dynamic>{'title': c.name},
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    );

/// يفتح الرابط في مشغّل خارجي. mode: ytv | mx | any (قائمة النظام)
/// يرجع false إذا تعذّر الفتح (غير مثبّت، أو رابط ملف محلي لا يمكن مشاركته).
Future<bool> launchExternal(Channel c, {required String mode}) async {
  if (!Platform.isAndroid) return false;
  // file:// أو مسار محلي لا يمكن تمريره لتطبيق آخر (FileUriExposedException)
  if (!c.url.toLowerCase().startsWith('http')) return false;
  try {
    if (mode == 'any') {
      // قائمة النظام بكل التطبيقات المثبّتة القادرة على تشغيل الرابط
      await _viewIntent(c).launchChooser(t('اختيار تطبيق خارجي'));
      return true;
    }
    if (mode == 'ytv') {
      // 1) النشاط الذي يستقبل الرابط فعلاً (فلتر VIEW) دون تحديد الشاشة الرئيسية: هذا ما يفتح القناة
      for (final type in _videoTypes) {
        final intent = _viewIntent(c, package: _ytvPackage, type: type);
        if (await intent.canResolveActivity() == true) {
          await intent.launch();
          return true;
        }
      }
      // 2) آخر حل: الشاشة الرئيسية (قد تفتح التطبيق دون تشغيل القناة إن كان لا يقبل روابط خارجية)
      final mainIntent = _viewIntent(c, package: _ytvPackage, component: _ytvActivity);
      if (await mainIntent.canResolveActivity() == true) {
        await mainIntent.launch();
        return true;
      }
      return false; // غير مثبّت
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

/// نقطة الدخول الوحيدة لتشغيل أي قناة/فيلم/حلقة حسب إعداد «المشغّل الافتراضي»:
///   internal = مشغّل داخلي 1 (media_kit)   exo = مشغّل داخلي 2 (ExoPlayer)
///   web = مشغّل داخلي 3 (Video.js)          ytv = YTV Pro (للقنوات المباشرة فقط)   mx = MX Player
/// [player] يتجاوز الإعداد (مثلاً 'mx' من قائمة المشغّل الداخلي).
/// يرجع true إذا فُتح مشغّل (داخلي أو خارجي).
Future<bool> openPlayer(
  BuildContext context,
  Channel c, {
  required bool live,
  List<Channel> playlist = const <Channel>[],
  String? player,
  bool fallbackToInternal = true,
  ValueChanged<Channel>? onChannelChanged,
}) async {
  // نلتقط كل ما يحتاج context قبل أي await
  final settings = context.read<AppSettings>();
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  var mode = player ?? settings.player;
  // YTV Pro للقنوات المباشرة فقط: الأفلام والمسلسلات والحلقات تعمل دائماً بالمشغّل الداخلي 1
  if (mode == 'ytv' && !live) mode = 'internal';

  if (mode == 'ytv' || mode == 'mx' || mode == 'any') {
    final ok = await launchExternal(c, mode: mode);
    if (ok) return true;
    messenger.showSnackBar(SnackBar(
      content: Text(t(fallbackToInternal
          ? 'المشغّل الخارجي غير متاح، سيتم استخدام المشغّل الداخلي'
          : 'المشغّل الخارجي غير متاح')),
    ));
    if (!fallbackToInternal) return false;
    mode = 'internal';
  }

  final Widget screen = switch (mode) {
    'exo' => ExoPlayerScreen(channel: c, isLive: live, playlist: playlist),
    'web' => WebPlayerScreen(channel: c, isLive: live, playlist: playlist),
    _ => PlayerScreen(channel: c, isLive: live, playlist: playlist, onChannelChanged: onChannelChanged),
  };
  await navigator.push(MaterialPageRoute(builder: (_) => screen));
  return true;
}
