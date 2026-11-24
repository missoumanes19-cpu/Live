import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/download_manager.dart';
import '../services/iptv_service.dart';
import '../state/app_settings.dart';
import '../widgets/subtitle_translate_dialog.dart';
import 'player_screen.dart';

String _size(int b) => b >= (1 << 30) ? '${(b / (1 << 30)).toStringAsFixed(2)} GB'
    : '${(b / (1 << 20)).toStringAsFixed(0)} MB';

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key});

  Future<void> _addSubtitle(BuildContext context, DownloadItem it, {bool translate = false}) async {
    final r = await FilePicker.platform.pickFiles(type: FileType.any);
    final path = r?.files.single.path;
    if (path == null) return;
    final ext = path.split('.').last.toLowerCase();
    if (!const ['srt', 'vtt', 'ass', 'ssa', 'sub'].contains(ext)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('صيغة الترجمة غير مدعومة'))));
      }
      return;
    }
    if (!context.mounted) return;
    var toAdd = path;
    if (translate) {
      final out = await translateSubtitleWithDialog(context, path);
      if (out == null || !context.mounted) return;
      toAdd = out;
    }
    await context.read<DownloadManager>().addSubtitle(it.id, toAdd);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('تمت إضافة الترجمة'))));
    }
  }

  static bool _isArabicCopy(String p) => p.split(RegExp(r'[\\/]')).last.contains('_ar_');

  /// أول ملف ترجمة نصي (srt/vtt) غير عربي مرفق بالتنزيل
  static String? _sourceSub(DownloadItem it) {
    for (final p in it.subtitles) {
      final e = p.toLowerCase();
      if ((e.endsWith('.srt') || e.endsWith('.vtt')) && !_isArabicCopy(p)) return p;
    }
    return null;
  }

  Future<bool> _translateSub(BuildContext context, DownloadItem it) async {
    final src = _sourceSub(it);
    if (src == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('أضف أولاً ملف ترجمة srt أو vtt'))));
      return false;
    }
    final out = await translateSubtitleWithDialog(context, src);
    if (!context.mounted) return false;
    if (out == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('تعذرت ترجمة الملف'))));
      return false;
    }
    await context.read<DownloadManager>().addSubtitle(it.id, out);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('تمت الترجمة، ستظهر بالعربية عند التشغيل'))));
    }
    return true;
  }

  Future<void> _playAsk(BuildContext context, DownloadItem it) async {
    final needs = _sourceSub(it) != null && !it.subtitles.any(_isArabicCopy);
    if (needs) {
      final yes = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
        backgroundColor: const Color(0xFF101A2A),
        title: Text(t('ترجمة الترجمة إلى العربية قبل التشغيل؟')),
        content: Text(t('تُترجم كل الترجمة أولاً ثم يبدأ الفيديو، فلا يحدث أي تأخير في ظهورها.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(t('تشغيل بدون ترجمة'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(t('ترجمة ثم تشغيل'))),
        ]));
      if (yes == true && context.mounted) await _translateSub(context, it);
    }
    if (context.mounted) {
      final fresh = context.read<DownloadManager>().byId(it.id) ?? it;
      _play(context, fresh);
    }
  }

  void _play(BuildContext context, DownloadItem it) {
    final local = Channel.fromMap({...it.channel.toMap(), 'url': it.path});
    Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(
      channel: local, isLive: false, subtitles: List<String>.from(it.subtitles), downloadId: it.id)));
  }

  Future<void> _confirmDelete(BuildContext context, DownloadItem it) async {
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
      backgroundColor: const Color(0xFF101A2A),
      title: Text(t('حذف التنزيل؟')),
      content: Text(it.channel.name),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: Text(t('إلغاء'))),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(t('حذف'))),
      ]));
    if (ok == true && context.mounted) await context.read<DownloadManager>().delete(it.id);
  }

  @override
  Widget build(BuildContext context) {
    final dm = context.watch<DownloadManager>();
    final items = dm.list;
    return Scaffold(
      appBar: AppBar(title: Text(t('التنزيلات'))),
      body: items.isEmpty
        ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(
            t('لا توجد تنزيلات بعد. اضغط تحميل على أي فيلم أو حلقة.'),
            textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54))))
        : ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final it = items[i];
              final done = it.status == 'done';
              final statusText = done ? '${t('جاهز بدون إنترنت')} • ${_size(it.total)}'
                  : it.status == 'downloading' ? '${(it.progress * 100).toStringAsFixed(0)}% • ${_size(it.received)} / ${it.total > 0 ? _size(it.total) : '?'}'
                  : it.status == 'queued' ? t('في الانتظار')
                  : it.status == 'error' ? '${t('فشل')}: ${it.error ?? ''}'
                  : '${t('متوقف')} • ${_size(it.received)}';
              return Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: const Color(0xFF101A2A), borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: done ? const Color(0xFF2E9E6B) : const Color(0xFF20344E))),
                child: Row(children: [
                  SizedBox(width: 48, height: 48, child: it.channel.logo.isEmpty
                    ? const Icon(Icons.movie_rounded, color: Colors.white54)
                    : CachedNetworkImage(imageUrl: it.channel.logo, fit: BoxFit.cover, memCacheWidth: 120,
                        errorWidget: (_, __, ___) => const Icon(Icons.movie_rounded, color: Colors.white54))),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(it.channel.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(statusText, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: it.status == 'error' ? Colors.redAccent : Colors.white60)),
                    if (!done) Padding(padding: const EdgeInsets.only(top: 6),
                      child: LinearProgressIndicator(value: it.total > 0 ? it.progress : null, minHeight: 3)),
                    if (it.subtitles.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4),
                      child: Text('${t('الترجمة')}: ${it.subtitles.length}',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF65D6A0)))),
                  ])),
                  if (done) IconButton(icon: const Icon(Icons.play_circle_fill_rounded, color: Color(0xFF42A5FF), size: 34),
                    tooltip: t('تشغيل'), onPressed: () => _playAsk(context, it)),
                  if (it.status == 'downloading' || it.status == 'queued') IconButton(
                    icon: const Icon(Icons.pause_circle_outline_rounded), onPressed: () => dm.pause(it.id)),
                  if (it.status == 'paused' || it.status == 'error') IconButton(
                    icon: const Icon(Icons.download_rounded), onPressed: () => dm.resume(it.id)),
                  PopupMenuButton<bool>(
                    icon: const Icon(Icons.subtitles_outlined), tooltip: t('إضافة ملف ترجمة'),
                    onSelected: (tr) => _addSubtitle(context, it, translate: tr),
                    itemBuilder: (_) => [
                      PopupMenuItem(value: false, child: Text(t('إضافة ملف ترجمة'))),
                      PopupMenuItem(value: true, child: Text(t('ترجمة إلى العربية وإضافة'))),
                    ]),
                  IconButton(icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                    onPressed: () => _confirmDelete(context, it)),
                ]));
            }),
    );
  }
}
