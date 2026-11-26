import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import '../services/parental_control.dart';
import '../services/update_checker.dart';
import '../config.dart';
import '../state/app_settings.dart';
import '../widgets/art.dart';
import 'diagnostics_screen.dart';

const _kMuted = Color(0xFF9BA9BD);

class SettingsScreen extends StatelessWidget {
  final List<String> categories;
  const SettingsScreen({super.key, required this.categories});

  /// بطاقة قسم: أيقونة متدرجة + عنوان + محتوى
  Widget _section(IconData icon, List<Color> colors, String title, List<Widget> children) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
    decoration: BoxDecoration(color: const Color(0xFF0D1726), borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF1B2D45))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        gradientBadge(icon, colors, size: 30),
        const SizedBox(width: 10),
        Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      ]),
      const SizedBox(height: 12),
      ...children,
    ]));

  Widget _label(String s) => Padding(padding: const EdgeInsets.only(bottom: 6),
    child: Text(s, style: const TextStyle(color: _kMuted, fontSize: 11.5)));

  Widget _note(String s) => Padding(padding: const EdgeInsets.only(bottom: 12),
    child: Text(s, style: const TextStyle(color: _kMuted, fontSize: 11.5)));

  Widget _chips<T>(List<(String, T)> options, T current, void Function(T) onPick) =>
    Padding(padding: const EdgeInsets.only(bottom: 12), child: Wrap(spacing: 6, runSpacing: 6, children: [
      for (final o in options) ChoiceChip(
        label: Text(o.$1, style: const TextStyle(fontSize: 12)),
        selected: current == o.$2,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onSelected: (_) => onPick(o.$2)),
    ]));

  Widget _opt<T>(String label, List<(String, T)> options, T current, void Function(T) onPick) =>
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_label(label), _chips<T>(options, current, onPick)]);

  Widget _tile(IconData icon, String title, {String? sub, VoidCallback? onTap}) => ListTile(
    dense: true, contentPadding: EdgeInsets.zero,
    leading: Icon(icon, size: 20, color: const Color(0xFF62B2FF)),
    title: Text(title, style: const TextStyle(fontSize: 13)),
    subtitle: sub == null ? null : Text(sub, style: const TextStyle(fontSize: 11)),
    trailing: onTap == null ? null : const Icon(Icons.chevron_right, size: 18, color: _kMuted),
    onTap: onTap);

  Widget _switch(String title, bool v, ValueChanged<bool> f, {String? sub}) => SwitchListTile(
    dense: true, contentPadding: EdgeInsets.zero, value: v, onChanged: f,
    title: Text(title, style: const TextStyle(fontSize: 13)),
    subtitle: sub == null ? null : Text(sub, style: const TextStyle(fontSize: 11)));

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    return Scaffold(
      backgroundColor: const Color(0xFF05080F),
      appBar: AppBar(backgroundColor: const Color(0xFF080D17),
        title: Text(t('الإعدادات'), style: const TextStyle(fontSize: 16))),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(padding: const EdgeInsets.all(16), children: [
          ArtBanner(padding: const EdgeInsets.all(14), child: Row(children: [
            gradientBadge(Icons.tune_rounded, kBlueGrad, size: 42),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('ANES TV', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text('v${AppConfig.version}', style: const TextStyle(fontSize: 11, color: Color(0xFFB6C9DF))),
            ])),
          ])),
          const SizedBox(height: 14),

          _section(Icons.language_rounded, kBlueGrad, t('اللغة'), [
            _chips<String>([('العربية', 'ar'), ('English', 'en'), ('Français', 'fr')], AppSettings.lang, s.setLanguage),
          ]),
          _section(Icons.palette_outlined, kTealGrad, t('شكل الواجهة'), [
            _chips<String>([(t('كلاسيكي'), 'classic'), (t('عصري'), 'modern')], s.uiStyle, s.setUiStyle),
          ]),

          _section(Icons.smart_display_rounded, kGreenGrad, t('المشغّل الافتراضي'), [
            _chips<String>([
              (t('مشغّل داخلي 1'), 'internal'),
              (t('مشغّل داخلي 2 (ExoPlayer)'), 'exo'),
              (t('مشغّل داخلي 3 (Video.js)'), 'web'),
              ('YTV Pro', 'ytv'),
              ('MX Player', 'mx'),
            ], s.player, s.setPlayer),
            if (s.player == 'exo') _note(t('المشغّل 2: بدون ترجمة مدمجة ولا اختيار مسار صوتي')),
            if (s.player == 'web') _note(t('المشغّل 3: يحتاج إنترنت لتحميل Video.js، ويدعم HLS وMP4 فقط')),
            if (s.player == 'ytv') _note(t('YTV Pro للقنوات المباشرة فقط؛ الأفلام والمسلسلات تعمل بالمشغّل الداخلي')),
          ]),

          _section(Icons.tune_rounded, kBlueGrad, t('المشغّل'), [
            _note(t('هذه الخيارات تخص المشغّل الداخلي 1 فقط')),
            _opt<String>(t('وضع فك التشفير'),
              [(t('تلقائي'), 'auto'), (t('عتاد (Hardware)'), 'hw'), (t('برمجي (Software)'), 'sw')], s.decoder, s.setDecoder),
            _opt<int>(t('نسبة العرض الافتراضية'),
              [(t('احتواء'), 0), (t('ملء الشاشة'), 1), (t('تمديد'), 2), (t('الحجم الأصلي'), 3)], s.fit, s.setFit),
            _opt<int>(t('حجم الذاكرة المؤقتة'),
              [('32 MB', 32), ('64 MB', 64), ('128 MB', 128), ('256 MB', 256)], s.bufferMb, s.setBufferMb),
            _opt<int>(t('التخزين المؤقت قبل التشغيل'),
              [(t('إيقاف'), 0), ('5 s', 5), ('10 s', 10), ('20 s', 20), ('30 s', 30)], s.prebufferSec, s.setPrebufferSec),
            _opt<String>(t('صيغة البث المباشر'),
              [(t('تلقائي'), 'auto'), ('TS', 'ts'), ('M3U8 (HLS)', 'm3u8')], s.liveFormat, s.setLiveFormat),
          ]),

          _section(Icons.speed_rounded, kTealGrad, t('الأداء'), [
            _switch(t('وضع الأجهزة الضعيفة'), s.lite, s.setLite,
              sub: t('يقلّل الذاكرة والتخزين المؤقت ويسرّع الواجهة')),
          ]),

          _section(Icons.settings_rounded, kBlueGrad, t('عام'), [
            _switch(t('التحديث التلقائي من السيرفر'), s.autoSync, s.setAutoSync),
            _tile(Icons.lock_rounded, t('الرقابة الأبوية'),
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => ParentalScreen(categories: categories)))),
            _tile(Icons.visibility_off_rounded, t('إخفاء تصنيفات'),
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => HiddenCategoriesScreen(categories: categories)))),
            _tile(Icons.speed_rounded, t('تشخيص الاتصال'),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DiagnosticsScreen()))),
            _tile(Icons.system_update_rounded, t('تحقق من التحديث'), onTap: () => checkForUpdate(context)),
            _tile(Icons.delete_sweep_rounded, t('مسح الذاكرة المؤقتة'),
              onTap: () async {
                await Hive.box('cache').clear();
                if (context.mounted) ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(t('تم مسح الذاكرة المؤقتة'))));
              }),
          ]),

          _section(Icons.info_outline_rounded, kGreenGrad, t('حول التطبيق'), [
            _tile(Icons.live_tv_rounded, 'ANES TV', sub: 'v${AppConfig.version}'),
          ]),
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
