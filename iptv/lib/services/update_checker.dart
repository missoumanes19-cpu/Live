import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config.dart';
import '../state/app_settings.dart';
import 'errors.dart';
import 'server_connector.dart';

Future<void> checkForUpdate(BuildContext context) async {
  final connector = context.read<ServerConnector>();
  final messenger = ScaffoldMessenger.of(context);
  if (connector.configUrl.isEmpty) return;
  try {
    final cfg = await connector.fetchConfig(connector.configUrl);
    final latest = cfg.latestVersion.isNotEmpty ? cfg.latestVersion : cfg.minVersion;
    if (latest.isEmpty || !ServerConnector.versionLess(AppConfig.version, latest)) {
      messenger.showSnackBar(SnackBar(content: Text(t('أنت تستخدم آخر إصدار'))));
      return;
    }
    if (!context.mounted) return;
    await showDialog(context: context, builder: (d) => AlertDialog(
      title: Text(t('تحديث متوفر')), content: Text('v$latest'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('OK')),
        if (cfg.updateUrl.isNotEmpty) FilledButton(
          onPressed: () { AndroidIntent(action: 'action_view', data: cfg.updateUrl).launch(); Navigator.pop(d); },
          child: Text(t('تنزيل'))),
      ]));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
  }
}
