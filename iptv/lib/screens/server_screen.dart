import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import '../services/iptv_service.dart';
import '../services/server_connector.dart';
import '../state/app_settings.dart';

typedef OnConnected = void Function(List<Channel> channels, String source);

void _finish(BuildContext ctx, OnConnected cb, List<Channel> ch, String label) {
  cb(ch, label);
  Navigator.of(ctx).popUntil((r) => r.isFirst);
}

Widget _field(String label, TextEditingController c, {String? hint, bool secret = false}) =>
    Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(
      controller: c, obscureText: secret,
      decoration: InputDecoration(labelText: label, hintText: hint, filled: true,
        fillColor: const Color(0xFF0D1726),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
    ));

/// قالب مشترك لصفحات الإدخال
class _FormPage extends StatelessWidget {
  final IconData icon; final String title, subtitle, status;
  final bool busy, error; final List<Widget> children;
  const _FormPage({required this.icon, required this.title, required this.subtitle,
    required this.status, required this.busy, required this.error, required this.children});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF05080F),
    appBar: AppBar(backgroundColor: const Color(0xFF080D17), title: Text(title)),
    body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640),
      child: ListView(padding: const EdgeInsets.all(22), children: [
        Row(children: [
          Container(width: 52, height: 52,
            decoration: BoxDecoration(color: const Color(0xFF12345A), borderRadius: BorderRadius.circular(14)),
            child: Icon(icon, color: const Color(0xFF62B2FF), size: 28)),
          const SizedBox(width: 14),
          Expanded(child: Text(subtitle, style: const TextStyle(color: Color(0xFF9BA9BD)))),
        ]),
        const SizedBox(height: 22),
        ...children,
        const SizedBox(height: 8),
        if (busy) const LinearProgressIndicator(),
        if (status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10),
          child: Text(status, style: TextStyle(color: error ? Colors.redAccent : const Color(0xFF65D6A0)))),
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
      setState(() { _busy = false; _msg = '${t('فشل الاتصال')}: $e'; });
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
      appBar: AppBar(backgroundColor: const Color(0xFF080D17), title: Text(t('ANES TV • السيرفرات'))),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(padding: const EdgeInsets.all(22), children: [
          Container(padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF123D70), Color(0xFF101827)]),
              borderRadius: BorderRadius.circular(17)),
            child: Row(children: [
              const Icon(Icons.cloud_done_rounded, size: 34, color: Color(0xFF75BDFF)),
              const SizedBox(width: 13),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t('اختر مصدر القنوات'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
                const SizedBox(height: 5),
                Text(type == null ? t('لا يوجد مصدر') : '${t('المصدر الحالي')}: ${name ?? type}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFFB6C9DF))),
              ])),
            ])),
          const SizedBox(height: 22),
          Wrap(spacing: 16, runSpacing: 16, children: [
            _SourceTile(icon: Icons.account_tree_rounded, title: 'Xtream Codes',
              subtitle: 'Host • User • Password', selected: type == 'xtream',
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => XtreamScreen(onConnected: onConnected)))),
            _SourceTile(icon: Icons.link_rounded, title: 'M3U',
              subtitle: 'Link / File', selected: type == 'm3u_url' || type == 'm3u_file',
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => M3uScreen(onConnected: onConnected)))),
            _SourceTile(icon: Icons.cloud_sync_rounded, title: t('السيرفر الأونلاين • GitHub'),
              subtitle: 'Auto update', selected: type == 'github',
              onTap: () => Navigator.push(context, MaterialPageRoute(
                builder: (_) => GithubScreen(onConnected: onConnected)))),
          ]),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
          if (_msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10),
            child: Text(_msg, style: TextStyle(color: _msg.startsWith(t('فشل الاتصال')) ? Colors.redAccent : const Color(0xFF65D6A0)))),
          if (profiles.isNotEmpty) ...[
            const SizedBox(height: 26),
            Text(t('السيرفرات المحفوظة'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            for (var i = 0; i < profiles.length; i++) Card(
              color: const Color(0xFF101A2A),
              child: ListTile(
                leading: Icon(profiles[i]['type'] == 'xtream' ? Icons.account_tree_rounded : Icons.link_rounded,
                  color: const Color(0xFF62B2FF)),
                title: Text('${profiles[i]['name']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${profiles[i]['user'] ?? profiles[i]['url'] ?? ''}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(icon: const Icon(Icons.delete_outline),
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
  const _SourceTile({required this.icon, required this.title, required this.subtitle,
    required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => SizedBox(width: 270, height: 150, child: InkWell(
    onTap: onTap, borderRadius: BorderRadius.circular(18),
    child: Ink(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: const Color(0xFF101A2A), borderRadius: BorderRadius.circular(18),
        border: Border.all(color: selected ? const Color(0xFF168BFF) : const Color(0xFF20344E), width: selected ? 2 : 1)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: const Color(0xFF62B2FF), size: 32),
        const Spacer(),
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(subtitle, style: const TextStyle(color: Color(0xFF9BA9BD), fontSize: 12)),
      ]))));
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
      setState(() { _busy = false; _err = true; _status = '${t('فشل الاتصال')}: $e'; });
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
      setState(() { _busy = false; _err = true; _status = '${t('فشل الاتصال')}: $e'; });
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
    icon: Icons.link_rounded, title: 'M3U', subtitle: 'Link / File',
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

// ======================= واجهة GitHub =======================
class GithubScreen extends StatefulWidget {
  final OnConnected onConnected;
  const GithubScreen({super.key, required this.onConnected});
  @override
  State<GithubScreen> createState() => _GithubScreenState();
}

class _GithubScreenState extends State<GithubScreen> {
  final _url = TextEditingController();
  bool _busy = false, _err = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _url.text = context.read<ServerConnector>().configUrl;
  }

  @override
  void dispose() { _url.dispose(); super.dispose(); }

  Future<void> _sync() async {
    setState(() { _busy = true; _err = false; _status = t('جارٍ الاتصال...'); });
    try {
      await Hive.box('settings').put('github_config_url', _url.text.trim());
      final ch = await context.read<ServerConnector>().syncGithub();
      if (!mounted) return;
      _finish(context, widget.onConnected, ch, 'GitHub');
    } catch (e) {
      if (!mounted) return;
      setState(() { _busy = false; _err = true; _status = '${t('فشل الاتصال')}: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    final last = Hive.box('settings').get('github_last_sync') as int?;
    final lastText = last == null ? t('لم يتم التحديث بعد')
        : DateTime.fromMillisecondsSinceEpoch(last).toString().substring(0, 16);
    final names = (Hive.box('settings').get('github_server_names', defaultValue: <dynamic>[]) as List)
        .map((e) => '$e').toList();
    final idx = Hive.box('settings').get('github_server_index', defaultValue: 0) as int;
    return _FormPage(
      icon: Icons.cloud_sync_rounded, title: t('السيرفر الأونلاين • GitHub'),
      subtitle: 'xtream_config.json', status: _status, busy: _busy, error: _err,
      children: [
        _field(t('رابط GitHub Raw لملف JSON'), _url,
          hint: 'https://raw.githubusercontent.com/USER/REPO/main/xtream_config.json'),
        if (names.length > 1) Padding(padding: const EdgeInsets.only(bottom: 12),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (var i = 0; i < names.length; i++) ChoiceChip(label: Text(names[i]), selected: i == idx,
              onSelected: _busy ? null : (_) async {
                await Hive.box('settings').put('github_server_index', i);
                _sync();
              }),
          ])),
        SwitchListTile(contentPadding: EdgeInsets.zero, value: s.autoSync,
          onChanged: s.setAutoSync, title: Text(t('التحديث التلقائي من GitHub'))),
        Padding(padding: const EdgeInsets.only(bottom: 14),
          child: Text('${t('آخر تحديث')}: $lastText',
            style: const TextStyle(color: Color(0xFF9BA9BD), fontSize: 12))),
        SizedBox(width: double.infinity, child: FilledButton.icon(
          onPressed: _busy ? null : _sync, icon: const Icon(Icons.sync),
          label: Text(t('حفظ وتحديث الآن')),
          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)))),
      ]);
  }
}
