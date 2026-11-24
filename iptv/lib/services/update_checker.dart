import 'dart:convert';
import 'dart:ffi' show Abi;
import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../config.dart';
import '../state/app_settings.dart';
import 'errors.dart';
import 'iptv_service.dart';
import 'server_connector.dart';

/// يستخرج user/repo من رابط الإعدادات (raw.githubusercontent.com/USER/REPO/...)
({String user, String repo})? repoFromConfigUrl(String url) {
  final m = RegExp(r'^https?://(?:raw\.githubusercontent\.com|github\.com|cdn\.jsdelivr\.net/gh)/([^/@]+)/([^/@]+)').firstMatch(url.trim());
  return m == null ? null : (user: m[1]!, repo: m[2]!.replaceAll('.git', ''));
}

/// يختار ملف APK المناسب لمعمارية الجهاز من أصول الإصدار
String? pickApkAsset(List assets) {
  final abi = Abi.current().toString(); // android_arm64 | android_arm | android_x64 ...
  final want = abi.contains('arm64') ? 'arm64-v8a' : abi.contains('arm') ? 'armeabi-v7a' : abi.contains('x64') ? 'x86_64' : '';
  String? any;
  for (final a in assets) {
    final name = '${a['name']}'.toLowerCase();
    if (!name.endsWith('.apk')) continue;
    any ??= '${a['browser_download_url']}';
    if (want.isNotEmpty && name.contains(want)) return '${a['browser_download_url']}';
  }
  return any;
}

Future<void> checkForUpdate(BuildContext context) async {
  final connector = context.read<ServerConnector>();
  final messenger = ScaffoldMessenger.of(context);
  final cfgUrl = connector.configUrl.isNotEmpty ? connector.configUrl : AppConfig.githubConfigUrl;
  try {
    String latest = '', apk = '', notes = '';
    // 1) آخر إصدار منشور على GitHub Releases (تلقائي بعد كل بناء)
    final repo = repoFromConfigUrl(cfgUrl);
    if (repo != null) {
      try {
        final res = await http.get(
          Uri.https('api.github.com', '/repos/${repo.user}/${repo.repo}/releases/latest'),
          headers: {...kHttpHeaders, 'Accept': 'application/vnd.github+json'}).timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          final d = jsonDecode(utf8.decode(res.bodyBytes)) as Map;
          latest = '${d['tag_name']}'.replaceFirst(RegExp(r'^[vV]'), '');
          apk = pickApkAsset((d['assets'] as List?) ?? const []) ?? '';
          notes = '${d['body'] ?? ''}'.trim();
        }
      } catch (_) {/* ننتقل إلى ملف الإعدادات */}
    }
    // 2) بديل: الحقلان latest_version / update_url في ملف الإعدادات
    if (latest.isEmpty && cfgUrl.isNotEmpty) {
      final cfg = await connector.fetchConfig(cfgUrl);
      latest = cfg.latestVersion.isNotEmpty ? cfg.latestVersion : cfg.minVersion;
      apk = cfg.updateUrl;
    }
    if (latest.isEmpty || !ServerConnector.versionLess(AppConfig.version, latest)) {
      messenger.showSnackBar(SnackBar(content: Text(t('أنت تستخدم آخر إصدار'))));
      return;
    }
    if (!context.mounted) return;
    await showDialog(context: context, builder: (d) => AlertDialog(
      backgroundColor: const Color(0xFF101A2A),
      title: Text(t('تحديث متوفر')),
      content: Text('v${AppConfig.version}  →  v$latest${notes.isEmpty ? '' : '\n\n${notes.length > 400 ? notes.substring(0, 400) : notes}'}'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('OK')),
        if (apk.isNotEmpty) FilledButton(
          onPressed: () { AndroidIntent(action: 'action_view', data: apk).launch(); Navigator.pop(d); },
          child: Text(t('تنزيل'))),
      ]));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
  }
}
