import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import '../services/parental_control.dart';
import '../state/app_settings.dart';

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
          _chips<String>([('العربية', 'ar'), ('English', 'en')], AppSettings.lang, s.setLanguage),
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
          _chips<int>([('16 MB', 16), ('32 MB', 32), ('64 MB', 64)], s.bufferMb, s.setBufferMb),
          _title(t('عام')),
          SwitchListTile(value: s.autoSync, onChanged: s.setAutoSync,
            title: Text(t('التحديث التلقائي من GitHub'))),
          ListTile(leading: const Icon(Icons.lock), title: Text(t('الرقابة الأبوية')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => ParentalScreen(categories: categories)))),
          ListTile(leading: const Icon(Icons.delete_sweep), title: Text(t('مسح الذاكرة المؤقتة')),
            onTap: () async {
              await Hive.box('cache').clear();
              if (context.mounted) ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text(t('تم مسح الذاكرة المؤقتة'))));
            }),
          _title(t('حول التطبيق')),
          const ListTile(leading: Icon(Icons.info_outline), title: Text('ANES TV'), subtitle: Text('v1.0.0')),
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
