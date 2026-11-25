import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import '../services/backup.dart';
import '../services/errors.dart';
import '../services/parental_control.dart';
import '../services/update_checker.dart';
import '../config.dart';
import '../state/app_settings.dart';
import 'diagnostics_screen.dart';

class SettingsScreen extends StatelessWidget {
  final List<String> categories;
  const SettingsScreen({super.key, required this.categories});

  Widget _title(String s) => Padding(padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
    child: Text(s, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF62B2FF))));

  Widget _chips<T>(List<(String, T)> options, T current, void Function(T) onPick) =>
    Wrap(spacing: 8, runSpacing: 8, children: [
      for (final o in options) ChoiceChip(label: Text(o.$1), selected: current == o.$2,
        onSelected: (_) => onPick(o.$2)),
    ]);

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    return Scaffold(
      appBar: AppBar(title: Text(t('الإعدادات'))),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(padding: const EdgeInsets.all(20), children: [
          _title(t('اللغة')),
          _chips<String>([('العربية', 'ar'), ('English', 'en'), ('Français', 'fr')], AppSettings.lang, s.setLanguage),
          _title(t('شكل الواجهة')),
          _chips<String>([(t('كلاسيكي'), 'classic'), (t('عصري'), 'modern')], s.uiStyle, s.setUiStyle),
          _title(t('المشغّل الافتراضي')),
          _chips<String>([(t('مشغّل داخلي'), 'internal'), ('YTV Pro', 'ytv'), ('MX Player', 'mx'),
            (t('اختيار تطبيق'), 'chooser'), ('Package', 'custom')], s.player, s.setPlayer),
          if (s.player == 'ytv') Padding(padding: const EdgeInsets.only(top: 8),
            child: Text(t('YTV Pro للقنوات المباشرة فقط؛ الأفلام والمسلسلات تعمل بالمشغّل الداخلي'),
              style: const TextStyle(color: Color(0xFF9BA9BD), fontSize: 12))),
          if (s.player == 'custom') Padding(padding: const EdgeInsets.only(top: 10),
            child: TextFormField(initialValue: s.customPackage, onChanged: s.setCustomPackage,
              decoration: InputDecoration(labelText: t('حزمة تطبيق مخصص'), hintText: 'com.example.player',
                border: const OutlineInputBorder()))),
          _title(t('المشغّل')),
          Text(t('وضع فك التشفير'), style: const TextStyle(color: Color(0xFF9BA9BD), fontSize: 12)),
          const SizedBox(height: 8),
          _chips<String>([(t('تلقائي'), 'auto'), (t('عتاد (Hardware)'), 'hw'), (t('برمجي (Software)'), 'sw')],
            s.decoder, s.setDecoder),
          const SizedBox(height: 16),
          Text(t('نسبة العرض الافتراضية'), style: const TextStyle(color: Color(0xFF9BA9BD), fontSize: 12)),
          const SizedBox(height: 8),
          _chips<int>([(t('احتواء'), 0), (t('ملء الشاشة'), 1), (t('تمديد'), 2), (t('الحجم الأصلي'), 3)],
            s.fit, s.setFit),
          const SizedBox(height: 16),
          Text(t('حجم الذاكرة المؤقتة'), style: const TextStyle(color: Color(0xFF9BA9BD), fontSize: 12)),
          const SizedBox(height: 8),
          _chips<int>([('32 MB', 32), ('64 MB', 64), ('128 MB', 128), ('256 MB', 256)], s.bufferMb, s.setBufferMb),
          const SizedBox(height: 16),
          Text(t('التخزين المؤقت قبل التشغيل'), style: const TextStyle(color: Color(0xFF9BA9BD), fontSize: 12)),
          const SizedBox(height: 8),
          _chips<int>([(t('إيقاف'), 0), ('5 s', 5), ('10 s', 10), ('20 s', 20), ('30 s', 30)],
            s.prebufferSec, s.setPrebufferSec),
          const SizedBox(height: 16),
          Text(t('صيغة البث المباشر'), style: const TextStyle(color: Color(0xFF9BA9BD), fontSize: 12)),
          const SizedBox(height: 8),
          _chips<String>([(t('تلقائي'), 'auto'), ('TS', 'ts'), ('M3U8 (HLS)', 'm3u8')], s.liveFormat, s.setLiveFormat),
          _title(t('الأداء')),
          SwitchListTile(value: s.lite, onChanged: s.setLite,
            title: Text(t('وضع الأجهزة الضعيفة')),
            subtitle: Text(t('يقلّل الذاكرة والتخزين المؤقت ويسرّع الواجهة'))),
          _title(t('عام')),
          SwitchListTile(value: s.autoSync, onChanged: s.setAutoSync,
            title: Text(t('التحديث التلقائي من السيرفر'))),
          ListTile(leading: const Icon(Icons.lock), title: Text(t('الرقابة الأبوية')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => ParentalScreen(categories: categories)))),
          ListTile(leading: const Icon(Icons.speed), title: Text(t('تشخيص الاتصال')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DiagnosticsScreen()))),
          ListTile(leading: const Icon(Icons.visibility_off), title: Text(t('إخفاء تصنيفات')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => HiddenCategoriesScreen(categories: categories)))),
          ListTile(leading: const Icon(Icons.system_update), title: Text(t('تحقق من التحديث')),
            onTap: () => checkForUpdate(context)),
          ListTile(leading: const Icon(Icons.save_alt_rounded), title: Text(t('تصدير نسخة احتياطية (ملف)')),
            onTap: () async {
              final m = ScaffoldMessenger.of(context);
              try {
                final bytes = Uint8List.fromList(utf8.encode(exportBackup()));
                final path = await FilePicker.platform.saveFile(
                  dialogTitle: 'ANES TV backup', fileName: 'anes_tv_backup.json', bytes: bytes);
                if (path != null) m.showSnackBar(SnackBar(content: Text(t('تم حفظ الملف'))));
              } catch (e) {
                m.showSnackBar(SnackBar(content: Text(friendlyError(e))));
              }
            }),
          ListTile(leading: const Icon(Icons.file_open_rounded), title: Text(t('استيراد نسخة احتياطية (ملف)')),
            onTap: () async {
              final m = ScaffoldMessenger.of(context);
              try {
                final r = await FilePicker.platform.pickFiles(type: FileType.any);
                final path = r?.files.single.path;
                if (path == null) return;
                await importBackup(await File(path).readAsString());
                m.showSnackBar(SnackBar(content: Text(t('تم الاستيراد، أعد تشغيل التطبيق'))));
              } catch (e) {
                m.showSnackBar(SnackBar(content: Text(friendlyError(e))));
              }
            }),
          ListTile(leading: const Icon(Icons.upload), title: Text(t('تصدير إلى الحافظة')),
            subtitle: Text(t('نسخ احتياطي')),
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: exportBackup()));
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t('تم النسخ'))));
            }),
          ListTile(leading: const Icon(Icons.download), title: Text(t('استيراد من الحافظة')),
            onTap: () async {
              final m = ScaffoldMessenger.of(context);
              try {
                final d = await Clipboard.getData('text/plain');
                await importBackup(d?.text ?? '');
                m.showSnackBar(SnackBar(content: Text(t('تم الاستيراد، أعد تشغيل التطبيق'))));
              } catch (e) {
                m.showSnackBar(SnackBar(content: Text(friendlyError(e))));
              }
            }),
          ListTile(leading: const Icon(Icons.delete_sweep), title: Text(t('مسح الذاكرة المؤقتة')),
            onTap: () async {
              await Hive.box('cache').clear();
              if (context.mounted) ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(t('تم مسح الذاكرة المؤقتة'))));
            }),
          _title(t('حول التطبيق')),
          ListTile(leading: const Icon(Icons.info_outline), title: const Text('ANES TV'), subtitle: Text('v${AppConfig.version}')),
        ]))),
    );
  }
}

class ParentalScreen extends StatelessWidget {
  final List<String> categories;
  const ParentalScreen({super.key, required this.categories});
  @override
  Widget build(BuildContext context) {
    final pc = context.watch<ParentalControl>();
    return Scaffold(
      appBar: AppBar(title: Text(t('الرقابة الأبوية'))),
      body: ListView(children: [
        ListTile(
          leading: const Icon(Icons.lock), title: const Text('PIN'),
          onTap: () async {
            final old = TextEditingController(), nw = TextEditingController();
            await showDialog(context: context, builder: (d) => AlertDialog(
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                if (pc.hasPin) TextField(controller: old, obscureText: true,
                    decoration: const InputDecoration(labelText: 'Old PIN')),
                TextField(controller: nw, obscureText: true, maxLength: 4,
                    decoration: const InputDecoration(labelText: 'New PIN')),
              ]),
              actions: [TextButton(onPressed: () {
                final ok = pc.setPin(nw.text, oldPin: old.text);
                Navigator.pop(d);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? 'OK' : 'Wrong PIN')));
              }, child: const Text('OK'))],
            ));
          },
        ),
        const Divider(),
        for (final c in categories)
          SwitchListTile(title: Text(c), value: pc.isLocked(c), onChanged: (_) => pc.toggleCategory(c)),
      ]),
    );
  }
}

class HiddenCategoriesScreen extends StatelessWidget {
  final List<String> categories;
  const HiddenCategoriesScreen({super.key, required this.categories});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    final hidden = s.hidden;
    return Scaffold(
      appBar: AppBar(title: Text(t('إخفاء تصنيفات'))),
      body: ListView.builder(itemCount: categories.length, itemBuilder: (_, i) => SwitchListTile(
        title: Text(categories[i]), value: hidden.contains(categories[i]),
        onChanged: (_) => s.toggleHidden(categories[i]))),
    );
  }
}
