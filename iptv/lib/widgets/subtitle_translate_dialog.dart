import 'dart:io';
import 'package:flutter/material.dart';
import '../services/subtitle_file.dart';
import '../services/subtitle_translator.dart';
import '../state/app_settings.dart';

/// يترجم ملف ترجمة كاملاً (srt / vtt / ass) إلى العربية مع نافذة تقدّم. يرجع مسار ملف srt العربي أو null
Future<String?> translateSubtitleWithDialog(BuildContext context, String path) async {
  var cancelled = false;
  final progress = ValueNotifier<double>(0);
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (d) => PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: const Color(0xFF101A2A),
        title: Text(t('جارٍ ترجمة ملف الترجمة إلى العربية')),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, v, __) => Column(mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(value: v > 0 ? v : null),
            const SizedBox(height: 10),
            Text('${(v * 100).round()}%'),
          ])),
        actions: [TextButton(onPressed: () => cancelled = true, child: Text(t('إلغاء')))],
      )));
  String? out;
  try {
    final ext = path.split('.').last.toLowerCase();
    final cues = parseSubtitle(decodeSubtitle(await File(path).readAsBytes()), ext);
    if (cues.isNotEmpty) {
      final tr = SubtitleTranslator(target: 'ar');
      final map = await tr.translateAll(cues.map((c) => c.text).toList(),
        onProgress: (p) => progress.value = p, isCancelled: () => cancelled);
      if (!cancelled) {
        for (final c in cues) { c.text = map[SubtitleTranslator.clean(c.text)] ?? SubtitleTranslator.clean(c.text); }
        final name = path.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.[^.]+$'), '');
        final f = File('${Directory.systemTemp.path}/ar_$name.srt');
        await f.writeAsString(toSrt(cues));
        out = f.path;
      }
    }
  } catch (_) {
    out = null;
  }
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  return cancelled ? null : out;
}
