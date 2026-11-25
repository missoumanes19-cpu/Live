import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import 'servers_screen.dart';
import '../services/iptv_service.dart';
import '../services/errors.dart';
import '../services/server_connector.dart';
import '../state/app_settings.dart';
import '../widgets/art.dart';

typedef OnConnected = void Function(List<Channel> channels, String source);

void _finish(BuildContext ctx, OnConnected cb, List<Channel> ch, String label) {
  cb(ch, label);
  Navigator.of(ctx).popUntil((r) => r.isFirst);
}

Widget _field(String label, TextEditingController c, {String? hint, bool secret = false}) =>
    Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(
      controller: c, obscureText: secret,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(labelText: label, hintText: hint, filled: true, isDense: true,
        labelStyle: const TextStyle(fontSize: 12.5),
        hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF5E6D82)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        fillColor: const Color(0xFF0D1726),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
    ));

const _kSub = Color(0xFFB6C9DF);

/// قالب مشترك لصفحات الإدخال
class _FormPage extends StatelessWidget {
  final IconData icon; final String title, subtitle, status;
  final bool busy, error; final List<Widget> children; final List<Color> colors;
  const _FormPage({required this.icon, required this.title, required this.subtitle,
    required this.status, required this.busy, required this.error, required this.children,
    this.colors = kBlueGrad});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF05080F),
    appBar: AppBar(backgroundColor: const Color(0xFF080D17),
      title: Text(title, style: const TextStyle(fontSize: 16))),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640),
      child: ListView(padding: const EdgeInsets.all(20), children: [
        ArtBanner(padding: const EdgeInsets.all(14), child: Row(children: [
          gradientBadge(icon, colors, size: 42),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 3),
            Text(subtitle, style: const TextStyle(color: _kSub, fontSize: 11.5)),
          ])),
        ])),
        const SizedBox(height: 20),
        ...children,
        const SizedBox(height: 8),
        if (busy) const LinearProgressIndicator(),
        if (status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10),
          child: Text(status, style: TextStyle(fontSize: 12.5,
            color: error ? Colors.redAccent : const Color(0xFF65D6A0)))),
      ]))),
  );
}

// ======================= القائمة الرئيسية للمصادر =======================
class ServerScreen extends StatefulWidget {
  final OnConnected onConnected;
  const ServerScreen({super.key, required this.onConnected});
  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<ServerScreen> {
  bool _busy = false;
  String _msg = '';

  Future<void> _useProfile(Map p) async {
    setState(() { _busy = true; _msg = t('جارٍ الاتصال...'); });
    try {
      final ch = await context.read<ServerConnector>().connectProfile(p);
      if (!mounted) return;
      _finish(context, widget.onConnected, ch, '${p['name']}');
    } catch (e) {
      if (!mounted) return;
      setState(() { _busy = false; _msg = '${t('فشل الاتصال')}: ${friendlyError(e)}'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppSettings>();
    final box = Hive.box('settings');
    final type = box.get('server_type') as String?;
    final name = box.get('last_server_name') as String?;
    final profiles = context.read<ServerConnector>().profiles;
    final onConnected = widget.onConnected;
    return Scaffold(
      backgroundColor: const Color(0xFF05080F),
      appBar: AppBar(backgroundColor: const Color(0xFF080D17),
        title: Text(t('ANES TV • السيرفرات'), style: const TextStyle(fontSize: 16))),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(padding: const EdgeInsets.all(20), children: [
          ArtBanner(padding: const EdgeInsets.fromLTRB(16, 16, 16, 16), child: Row(children: [
            gradientBadge(Icons.cloud_done_rounded, kBlueGrad, size: 46),
            const SizedBox(width: 13),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('اختر مصدر القنوات'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(type == null || type == 'none' ? t('لا يوجد مصدر') : '${t('المصدر الحالي')}: ${name ?? type}',
                style: const TextStyle(fontSize: 11, color: _kSub)),
            ])),
          ])),
          const SizedBox(height: 18),
          Wrap(spacing: 12, runSpacing: 12, children: [
            _SourceTile(icon: Icons.account_tree_rounded, title: 'Xtream Codes',
              subtitle: 'Host • User • Password', selected: type == 'xtream', colors: kBlueGrad,
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => XtreamScreen(onConnected: onConnected)))),
            _SourceTile(icon: Icons.link_rounded, title: 'M3U',
              subtitle: 'Link / File', selected: type == 'm3u_url' || type == 'm3u_file', colors: kTealGrad,
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => M3uScreen(onConnected: onConnected)))),
            _SourceTile(icon: Icons.cloud_sync_rounded, title: t('السيرفر الأونلاين'),
              subtitle: 'Auto update', selected: type == 'github', colors: kGreenGrad,
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => GithubScreen(onConnected: onConnected)))),
          ]),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
          if (_msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10),
            child: Text(_msg, style: TextStyle(fontSize: 12.5,
              color: _msg.startsWith(t('فشل الاتصال')) ? Colors.redAccent : const Color(0xFF65D6A0)))),
          if (profiles.isNotEmpty) ...[
            const SizedBox(height: 22),
            Row(children: [
              Expanded(child: Text(t('السيرفرات المحفوظة'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold))),
              TextButton.icon(icon: const Icon(Icons.dns_rounded, size: 16),
                label: Text(t('إدارة السيرفرات'), style: const TextStyle(fontSize: 12)),
                onPressed: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => ServersScreen(onConnected: widget.onConnected))).then((_) { if (mounted) setState(() {}); })),
            ]),
            const SizedBox(height: 6),
            for (var i = 0; i < profiles.length; i++) Card(
              color: const Color(0xFF101A2A),
              margin: const EdgeInsets.only(bottom: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: Color(0xFF1B2D45))),
              child: ListTile(
                dense: true,
                leading: gradientBadge(profiles[i]['type'] == 'xtream' ? Icons.account_tree_rounded : Icons.link_rounded,
                  profiles[i]['type'] == 'xtream' ? kBlueGrad : kTealGrad, size: 34),
                title: Text('${profiles[i]['name']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                subtitle: Text('${profiles[i]['user'] ?? profiles[i]['url'] ?? ''}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                trailing: IconButton(icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () async {
                    await context.read<ServerConnector>().deleteProfile(i);
                    if (mounted) setState(() {});
                  }),
                onTap: _busy ? null : () => _useProfile(profiles[i]),
              )),
          ],
        ]))),
    );
  }
}

class _SourceTile extends StatelessWidget {
  final IconData icon; final String title, subtitle; final bool selected; final VoidCallback onTap;
  final List<Color> colors;
  const _SourceTile({required this.icon, required this.title, required this.subtitle,
    required this.selected, required this.onTap, required this.colors});
  @override
  Widget build(BuildContext context) => SizedBox(width: 212, height: 118, child: InkWell(
    onTap: onTap, borderRadius: BorderRadius.circular(16),
    child: Ink(
      decoration: BoxDecoration(color: const Color(0xFF101A2A), borderRadius: BorderRadius.circular(16),
        border: Border.all(color: selected ? colors.first : const Color(0xFF20344E), width: selected ? 1.8 : 1)),
      child: ClipRRect(borderRadius: BorderRadius.circular(15), child: Stack(fit: StackFit.expand, children: [
        Positioned(bottom: -16, right: -10,
          child: Icon(icon, size: 92, color: colors.first.withAlpha(34))),
        Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            gradientBadge(icon, colors, size: 34),
            const Spacer(),
            if (selected) Icon(Icons.check_circle_rounded, size: 18, color: colors.first),
          ]),
          const Spacer(),
          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFF9BA9BD), fontSize: 10.5)),
        ])),
      ])))));
}

// ======================= واجهة Xtream =======================
class XtreamScreen extends StatefulWidget {
  final OnConnected onConnected;
  const XtreamScreen({super.key, required this.onConnected});
  @override
  State<XtreamScreen> createState() => _XtreamScreenState();
}

class _XtreamScreenState extends State<XtreamScreen> {
  final _host = TextEditingController(), _user = TextEditingController(), _pass = TextEditingController();
  bool _busy = false, _err = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    final b = Hive.box('settings');
    _host.text = b.get('xt_host', defaultValue: '') as String;
    _user.text = b.get('xt_user', defaultValue: '') as String;
    _pass.text = b.get('xt_pass', defaultValue: '') as String;
  }

  @override
  void dispose() { _host.dispose(); _user.dispose(); _pass.dispose(); super.dispose(); }

  Future<void> _connect() async {
    setState(() { _busy = true; _err = false; _status = t('جارٍ الاتصال...'); });
    try {
      final ch = await context.read<ServerConnector>().xtream(_host.text, _user.text, _pass.text);
      if (!mounted) return;
      _finish(context, widget.onConnected, ch, 'Xtream');
    } catch (e) {
      if (!mounted) return;
      setState(() { _busy = false; _err = true; _status = '${t('فشل الاتصال')}: ${friendlyError(e)}'; });
    }
  }

  @override
  Widget build(BuildContext context) => _FormPage(
    icon: Icons.account_tree_rounded, title: 'Xtream Codes',
    subtitle: 'Host • Username • Password', status: _status, busy: _busy, error: _err,
    children: [
      _field(t('رابط السيرفر / Host'), _host, hint: 'http://example.com:8080'),
      _field(t('اسم المستخدم'), _user),
      _field(t('كلمة المرور'), _pass, secret: true),
      SizedBox(width: double.infinity, child: FilledButton.icon(
        onPressed: _busy ? null : _connect, icon: const Icon(Icons.link),
        label: Text(t('اتصال وتحميل القنوات')),
        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)))),
    ]);
}

// ======================= واجهة M3U =======================
class M3uScreen extends StatefulWidget {
  final OnConnected onConnected;
  const M3uScreen({super.key, required this.onConnected});
  @override
  State<M3uScreen> createState() => _M3uScreenState();
}

class _M3uScreenState extends State<M3uScreen> {
  final _url = TextEditingController();
  bool _busy = false, _err = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _url.text = Hive.box('settings').get('m3u_url', defaultValue: '') as String;
  }

  @override
  void dispose() { _url.dispose(); super.dispose(); }

  Future<void> _run(Future<List<Channel>> Function() job, String label) async {
    setState(() { _busy = true; _err = false; _status = t('جارٍ الاتصال...'); });
    try {
      final ch = await job();
      if (!mounted) return;
      _finish(context, widget.onConnected, ch, label);
    } catch (e) {
      if (!mounted) return;
      setState(() { _busy = false; _err = true; _status = '${t('فشل الاتصال')}: ${friendlyError(e)}'; });
    }
  }

  Future<void> _pick() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['m3u', 'm3u8'], withData: true);
      if (result == null || result.files.isEmpty) return;
      final bytes = result.files.single.bytes;
      if (bytes == null) throw Exception('تعذرت قراءة الملف');
      final text = utf8.decode(bytes, allowMalformed: true);
      if (!mounted) return;
      await _run(() => context.read<ServerConnector>().m3uText(text), result.files.single.name);
    } catch (e) {
      if (!mounted) return;
      setState(() { _err = true; _status = '$e'; });
    }
  }

  @override
  Widget build(BuildContext context) => _FormPage(
    icon: Icons.link_rounded, title: 'M3U', subtitle: 'Link / File', colors: kTealGrad,
    status: _status, busy: _busy, error: _err,
    children: [
      _field(t('رابط M3U'), _url, hint: 'https://example.com/playlist.m3u'),
      SizedBox(width: double.infinity, child: FilledButton.icon(
        onPressed: _busy ? null : () => _run(
          () => context.read<ServerConnector>().m3uUrl(_url.text), 'M3U'),
        icon: const Icon(Icons.link), label: Text(t('اتصال وتحميل القنوات')),
        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)))),
      const SizedBox(height: 14),
      SizedBox(width: double.infinity, child: OutlinedButton.icon(
        onPressed: _busy ? null : _pick, icon: const Icon(Icons.folder_open),
        label: Text(t('اختيار ملف M3U / M3U8')),
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(15)))),
    ]);
}

// ======================= واجهة السيرفر الأونلاين =======================
// رابط ملف الإعدادات لا يظهر في الواجهة نهائياً؛ يُقرأ من إعداد البناء (CONFIG_URL).
class GithubScreen extends StatefulWidget {
  final OnConnected onConnected;
  const GithubScreen({super.key, required this.onConnected});
  @override
  State<GithubScreen> createState() => _GithubScreenState();
}

class _GithubScreenState extends State<GithubScreen> {
  bool _busy = false, _err = false;
  String _status = '';

  Future<void> _sync() async {
    final connector = context.read<ServerConnector>();
    if (connector.configUrl.isEmpty) {
      setState(() { _err = true; _status = t('السيرفر الأونلاين غير مُعدّ في هذه النسخة'); });
      return;
    }
    setState(() { _busy = true; _err = false; _status = t('جارٍ الاتصال...'); });
    try {
      final ch = await connector.syncGithub();
      if (!mounted) return;
      _finish(context, widget.onConnected, ch, 'أونلاين');
    } catch (e) {
      if (!mounted) return;
      setState(() { _busy = false; _err = true; _status = '${t('فشل الاتصال')}: ${friendlyError(e)}'; });
    }
  }

  Future<void> _disconnect() async {
    await context.read<ServerConnector>().disconnect();
    if (!mounted) return;
    _finish(context, widget.onConnected, <Channel>[], '');
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    final box = Hive.box('settings');
    final connected = box.get('server_type') == 'github';
    final last = box.get('github_last_sync') as int?;
    final lastText = last == null ? t('لم يتم التحديث بعد')
        : DateTime.fromMillisecondsSinceEpoch(last).toString().substring(0, 16);
    final names = (box.get('github_server_names', defaultValue: <dynamic>[]) as List).map((e) => '$e').toList();
    final idx = box.get('github_server_index', defaultValue: 0) as int;
    return _FormPage(
      icon: Icons.cloud_sync_rounded, title: t('السيرفر الأونلاين'), colors: kGreenGrad,
      subtitle: t('تحديث تلقائي'), status: _status, busy: _busy, error: _err,
      children: [
        Container(padding: const EdgeInsets.all(14), margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(color: const Color(0xFF101A2A), borderRadius: BorderRadius.circular(14),
            border: Border.all(color: connected ? const Color(0xFF2E9E6B) : const Color(0xFF20344E))),
          child: Row(children: [
            Icon(connected ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
              color: connected ? const Color(0xFF65D6A0) : const Color(0xFF9BA9BD), size: 26),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(connected ? t('متصل') : t('غير متصل'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 3),
              Text('${t('آخر تحديث')}: $lastText', style: const TextStyle(color: Color(0xFF9BA9BD), fontSize: 11)),
            ])),
          ])),
        if (names.length > 1) Padding(padding: const EdgeInsets.only(bottom: 12),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (var i = 0; i < names.length; i++) ChoiceChip(
              label: Text(names[i], style: const TextStyle(fontSize: 12)), selected: i == idx,
              visualDensity: VisualDensity.compact,
              onSelected: _busy ? null : (_) async {
                await Hive.box('settings').put('github_server_index', i);
                _sync();
              }),
          ])),
        SwitchListTile(contentPadding: EdgeInsets.zero, dense: true, value: s.autoSync,
          onChanged: s.setAutoSync,
          title: Text(t('التحديث التلقائي من السيرفر'), style: const TextStyle(fontSize: 13))),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: FilledButton.icon(onPressed: _busy ? null : _sync, icon: const Icon(Icons.power_settings_new, size: 18),
            label: Text(connected ? t('تحديث الآن') : t('اتصال'), style: const TextStyle(fontSize: 13)),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 13)))),
          if (connected) ...[
            const SizedBox(width: 12),
            Expanded(child: OutlinedButton.icon(onPressed: _busy ? null : _disconnect, icon: const Icon(Icons.link_off, size: 18),
              label: Text(t('قطع الاتصال'), style: const TextStyle(fontSize: 13)),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent, padding: const EdgeInsets.symmetric(vertical: 13)))),
          ],
        ]),
      ]);
  }
}
