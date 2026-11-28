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

  /// بطاقة قسم: صورة (تتلوّن بلون التطبيق المختار) + عنوان + محتوى
  Widget _section(String img, String title, List<Widget> children, {String? subtitle}) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(color: const Color(0xFF0D1726), borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFF1B2D45))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // ترويسة القسم بتدرّج لون التطبيق
      Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(gradient: LinearGradient(colors: kBannerGrad,
          begin: AlignmentDirectional.centerStart, end: AlignmentDirectional.centerEnd)),
        child: Row(children: [
          Container(width: 44, height: 44, padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(color: Colors.black.withAlpha(90), borderRadius: BorderRadius.circular(13),
              border: Border.all(color: kAccent.withAlpha(90))),
            child: Image.asset('assets/settings/$img.png', color: kAccent2, colorBlendMode: BlendMode.srcIn)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold)),
            if (subtitle != null) Text(subtitle, style: const TextStyle(fontSize: 11, color: Color(0xFFC9D6E6))),
          ])),
        ]),
      ),
      Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 4), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: children)),
    ]));

  /// اختيار لوحة الألوان: دوائر بتدرّج كل لوحة، والمختارة بحلقة
  Widget _palettePicker(AppSettings s) => Padding(padding: const EdgeInsets.only(bottom: 10),
    child: Wrap(spacing: 12, runSpacing: 10, children: [
      for (final p in kPalettes) GestureDetector(
        onTap: () => s.setPalette(p.id),
        child: SizedBox(width: 62, child: Column(children: [
          AnimatedContainer(duration: const Duration(milliseconds: 180), width: 52, height: 52,
            decoration: BoxDecoration(shape: BoxShape.circle,
              gradient: LinearGradient(colors: p.g1, begin: Alignment.topLeft, end: Alignment.bottomRight),
              border: Border.all(color: s.palette == p.id ? Colors.white : Colors.transparent, width: 2.5),
              boxShadow: s.palette == p.id ? [BoxShadow(color: p.accent.withAlpha(110), blurRadius: 12)] : null),
            child: s.palette == p.id ? const Icon(Icons.check_rounded, color: Colors.white) : null),
          const SizedBox(height: 5),
          Text(t(p.label), style: TextStyle(fontSize: 11.5,
            color: s.palette == p.id ? Colors.white : _kMuted,
            fontWeight: s.palette == p.id ? FontWeight.bold : FontWeight.normal)),
        ])),
      ),
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
    leading: Icon(icon, size: 20, color: kAccent3),
    title: Text(title, style: const TextStyle(fontSize: 13)),
    subtitle: sub == null ? null : Text(sub, style: const TextStyle(fontSize: 11)),
    trailing: onTap == null ? null : const Icon(Icons.chevron_right, size: 18, color: _kMuted),
    onTap: onTap);

  Widget _switch(String title, bool v, ValueChanged<bool> f, {String? sub}) => SwitchListTile(
    dense: true, contentPadding: EdgeInsets.zero, value: v, onChanged: f,
    title: Text(title, style: const TextStyle(fontSize: 13)),
    subtitle: sub == null ? null : Text(sub, style: const TextStyle(fontSize: 11)));

  Future<void> _autoSubsDialog(BuildContext context) async {
    final box = Hive.box('settings');
    var on = box.get('auto_subs', defaultValue: true) == true;
    final key = TextEditingController(text: '${box.get('os_api_key', defaultValue: '')}');
    final user = TextEditingController(text: '${box.get('os_user', defaultValue: '')}');
    final pass = TextEditingController(text: '${box.get('os_pass', defaultValue: '')}');
    await showDialog(context: context, builder: (d) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
      backgroundColor: const Color(0xFF101A2A),
      title: Text(t('ترجمة التنزيلات التلقائية')),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        SwitchListTile(contentPadding: EdgeInsets.zero, value: on, onChanged: (v) => setS(() => on = v),
          title: Text(t('جلب الترجمة تلقائياً عند التحميل'), style: const TextStyle(fontSize: 13))),
        Align(alignment: AlignmentDirectional.centerStart, child: Text(
          t('اختياري: حساب OpenSubtitles مجاني يزيد فرص إيجاد الترجمة (api.opensubtitles.com)'),
          style: const TextStyle(fontSize: 11, color: _kMuted))),
        TextField(controller: key, decoration: const InputDecoration(labelText: 'API Key'), textDirection: TextDirection.ltr),
        TextField(controller: user, decoration: InputDecoration(labelText: t('اسم المستخدم')), textDirection: TextDirection.ltr),
        TextField(controller: pass, obscureText: true, decoration: InputDecoration(labelText: t('كلمة المرور')), textDirection: TextDirection.ltr),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: Text(t('إلغاء'))),
        FilledButton(onPressed: () async {
          await box.put('auto_subs', on);
          await box.put('os_api_key', key.text.trim());
          await box.put('os_user', user.text.trim());
          await box.put('os_pass', pass.text);
          if (d.mounted) Navigator.pop(d);
        }, child: Text(t('حفظ'))),
      ])));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();

    final colA = <Widget>[
      _section('lang', t('اللغة'), [
        _chips<String>([('العربية', 'ar'), ('English', 'en'), ('Français', 'fr')], AppSettings.lang, s.setLanguage),
      ]),
      _section('palette', t('ألوان التطبيق'), subtitle: t('لون متناسق لكل الواجهة، يتغير فوراً'), [
        _palettePicker(s),
      ]),
      _section('ui', t('شكل الواجهة'), [
        _chips<String>([(t('كلاسيكي'), 'classic'), (t('عصري'), 'modern')], s.uiStyle, s.setUiStyle),
      ]),
      _section('player', t('المشغّل الافتراضي'), [
        _chips<String>([
          (t('مشغّل داخلي 1'), 'internal'),
          (t('مشغّل داخلي 2 (ExoPlayer)'), 'exo'),
          (t('مشغّل داخلي 3 (Video.js)'), 'web'),
          ('YTV Pro', 'ytv'),
          ('MX Player', 'mx'),
          (t('اختيار تطبيق خارجي'), 'any'),
        ], s.player, s.setPlayer),
        if (s.player == 'exo') _note(t('المشغّل 2: بدون ترجمة مدمجة ولا اختيار مسار صوتي')),
        if (s.player == 'web') _note(t('المشغّل 3: يحتاج إنترنت لتحميل Video.js، ويدعم HLS وMP4 فقط')),
        if (s.player == 'ytv') _note(t('YTV Pro للقنوات المباشرة فقط؛ الأفلام والمسلسلات تعمل بالمشغّل الداخلي')),
        if (s.player == 'any') _note(t('يعرض قائمة بالتطبيقات المثبّتة القادرة على تشغيل الرابط')),
      ]),
      _section('tune', t('المشغّل'), [
        _note(t('هذه الخيارات تخص المشغّل الداخلي 1 فقط')),
        _opt<String>(t('وضع فك التشفير'),
          [(t('تلقائي'), 'auto'), (t('عتاد (Hardware)'), 'hw'), (t('برمجي (Software)'), 'sw')], s.decoder, s.setDecoder),
        _opt<int>(t('نسبة العرض الافتراضية'),
          [(t('احتواء'), 0), (t('ملء الشاشة'), 1), (t('تمديد'), 2), (t('الحجم الأصلي'), 3), ('16:9', 4), ('4:3', 5)], s.fit, s.setFit),
        _opt<int>(t('حجم الذاكرة المؤقتة'),
          [('32 MB', 32), ('64 MB', 64), ('128 MB', 128), ('256 MB', 256)], s.bufferMb, s.setBufferMb),
        _opt<int>(t('التخزين المؤقت قبل التشغيل'),
          [(t('إيقاف'), 0), ('5 s', 5), ('10 s', 10), ('20 s', 20), ('30 s', 30)], s.prebufferSec, s.setPrebufferSec),
        _opt<String>(t('صيغة البث المباشر'),
          [(t('تلقائي'), 'auto'), ('TS', 'ts'), ('M3U8 (HLS)', 'm3u8')], s.liveFormat, s.setLiveFormat),
      ]),
    ];

    final colB = <Widget>[
      _section('speed', t('الأداء'), [
        _switch(t('وضع الأجهزة الضعيفة'), s.lite, s.setLite,
          sub: t('يقلّل الذاكرة والتخزين المؤقت ويسرّع الواجهة')),
        _switch(t('تكييف الذاكرة المؤقتة تلقائياً'), s.adaptiveBuffer, s.setAdaptiveBuffer,
          sub: t('يزيد التخزين مؤقتاً عند تقطّع الاتصال ثم يعود تدريجياً')),
      ]),
      _section('subs', t('ترجمة التنزيلات التلقائية'), [
        _opt<String>(t('لغة الترجمة'), const [
          ('العربية', 'ar'), ('English', 'en'), ('Français', 'fr'), ('Español', 'es'), ('Türkçe', 'tr'),
          ('Deutsch', 'de'), ('Русский', 'ru'), ('فارسی', 'fa'), ('Português', 'pt'), ('Italiano', 'it'),
        ], s.subLang, s.setSubLang),
        _tile(Icons.subtitles_rounded, t('ترجمة التنزيلات التلقائية'),
          sub: t('تحميل النص الأصلي + الترجمة العربية مع كل فيلم أو حلقة'),
          onTap: () => _autoSubsDialog(context)),
      ]),
      _section('gear', t('عام'), [
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
      _section('info', t('حول التطبيق'), [
        _tile(Icons.live_tv_rounded, 'ANES TV', sub: 'v${AppConfig.version}'),
      ]),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF05080F),
      appBar: AppBar(backgroundColor: const Color(0xFF080D17),
        title: Text(t('الإعدادات'), style: const TextStyle(fontSize: 16))),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1040),
        child: ListView(padding: const EdgeInsets.all(16), children: [
          // ترويسة بالشعار
          ArtBanner(padding: const EdgeInsets.all(14), child: Row(children: [
            ClipRRect(borderRadius: BorderRadius.circular(16),
              child: Image.asset('assets/logo.png', width: 72, height: 72, fit: BoxFit.cover)),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('ANES TV', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
              const SizedBox(height: 3),
              Text('v${AppConfig.version}', style: const TextStyle(fontSize: 11.5, color: Color(0xFFD7E3F2))),
            ])),
          ])),
          const SizedBox(height: 14),
          LayoutBuilder(builder: (ctx, c) => c.maxWidth >= 720
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Column(children: colA)),
                const SizedBox(width: 14),
                Expanded(child: Column(children: colB)),
              ])
            : Column(children: [...colA, ...colB])),
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
