import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../services/iptv_service.dart';

class ServerScreen extends StatefulWidget {
  final void Function(List<Channel> channels, String source) onConnected;
  const ServerScreen({super.key, required this.onConnected});

  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<ServerScreen> {
  final _host = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _m3u = TextEditingController();
  final _github = TextEditingController();
  bool _busy = false;
  String _status = 'اختر نوع السيرفر ثم اتصل';
  String? _lastSource;
  Box get _settings => Hive.box('settings');

  @override
  void initState() {
    super.initState();
    _host.text = _settings.get('xt_host', defaultValue: '') as String;
    _user.text = _settings.get('xt_user', defaultValue: '') as String;
    _pass.text = _settings.get('xt_pass', defaultValue: '') as String;
    _m3u.text = _settings.get('m3u_url', defaultValue: '') as String;
    _github.text = _settings.get('github_config_url', defaultValue: '') as String;
    _lastSource = _settings.get('server_type') as String?;
  }

  @override
  void dispose() {
    _host.dispose(); _user.dispose(); _pass.dispose();
    _m3u.dispose(); _github.dispose();
    super.dispose();
  }

  String _normalHost(String value) {
    var v = value.trim();
    if (v.isEmpty) throw Exception('أدخل عنوان السيرفر');
    if (!v.startsWith('http://') && !v.startsWith('https://')) v = 'http://$v';
    return v.endsWith('/') ? v.substring(0, v.length - 1) : v;
  }

  Future<void> _run(Future<List<Channel>> Function() action, String label, String type) async {
    setState(() { _busy = true; _status = 'جارٍ الاتصال بـ $label ...'; });
    try {
      final channels = await action();
      if (channels.isEmpty) throw Exception('تم الاتصال لكن لم يتم العثور على قنوات');
      await _settings.put('server_type', type);
      await _settings.put('last_server_name', label);
      if (!mounted) return;
      setState(() { _busy = false; _status = 'متصل بنجاح • ${channels.length} قناة'; _lastSource = type; });
      widget.onConnected(channels, label);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم الاتصال بـ $label')));
    } catch (e) {
      if (!mounted) return;
      setState(() { _busy = false; _status = 'فشل الاتصال: $e'; });
    }
  }

  Future<void> _connectXtream() async {
    await _settings.put('xt_host', _host.text.trim());
    await _settings.put('xt_user', _user.text.trim());
    await _settings.put('xt_pass', _pass.text);
    await _run(() async {
      final host = _normalHost(_host.text);
      return context.read<IptvService>().streams(host, _user.text.trim(), _pass.text, 'live');
    }, 'Xtream Codes', 'xtream');
  }

  Future<void> _connectM3u() async {
    await _settings.put('m3u_url', _m3u.text.trim());
    await _settings.put('server_type', 'm3u_url');
    await _run(() => context.read<IptvService>().loadM3u(_m3u.text.trim(), force: true),
        'رابط M3U', 'm3u_url');
  }

  Future<void> _connectGithub() async {
    final configUrl = _github.text.trim();
    await _settings.put('github_config_url', configUrl);
    await _run(() async {
      if (configUrl.isEmpty) throw Exception('أدخل رابط ملف إعدادات GitHub JSON');
      final response = await http.get(Uri.parse(configUrl), headers: {
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
      }).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) {
        throw Exception('GitHub HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) {
        throw Exception('تنسيق JSON غير صحيح');
      }
      if (decoded['status']?.toString().toLowerCase() != 'active') {
        throw Exception('الإعدادات غير مفعّلة (status ليس active)');
      }
      final servers = decoded['xtream_servers'];
      if (servers is! List || servers.isEmpty) {
        throw Exception('لا توجد خوادم داخل xtream_servers');
      }
      final server = servers.firstWhere(
        (item) => item is Map &&
          (item['host']?.toString().isNotEmpty ?? false) &&
          (item['username']?.toString().isNotEmpty ?? false) &&
          (item['password']?.toString().isNotEmpty ?? false),
        orElse: () => throw Exception('بيانات Xtream ناقصة في ملف JSON'),
      ) as Map;
      final host = _normalHost(server['host'].toString());
      final username = server['username'].toString();
      final password = server['password'].toString();
      final serverName = server['server_name']?.toString() ?? 'GitHub Xtream';

      // Keep the selected credentials locally for the reconnect action.
      await _settings.put('xt_host', host);
      await _settings.put('xt_user', username);
      await _settings.put('xt_pass', password);
      await _settings.put('github_config_url', configUrl);
      await _settings.put('server_type', 'github');
      _host.text = host;
      _user.text = username;
      _pass.text = password;
      return context.read<IptvService>().streams(
        host, username, password, 'live', force: true);
    }, 'GitHub • Xtream', 'github');
  }

  Future<void> _pickM3u() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['m3u', 'm3u8'], withData: true);
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null) throw Exception('تعذرت قراءة الملف');
      final content = utf8.decode(bytes, allowMalformed: true);
      await _run(() async => context.read<IptvService>().parseM3u(content),
          file.name, 'm3u_file');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'تعذر فتح الملف: $e');
    }
  }

  Widget _field(String label, TextEditingController c, {String? hint, bool secret = false}) =>
      Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(
        controller: c, obscureText: secret,
        decoration: InputDecoration(labelText: label, hintText: hint,
          filled: true, fillColor: const Color(0xFF0D1726),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
      ));

  Widget _serverCard({required IconData icon, required String title, required String subtitle,
      required Widget content, required VoidCallback onConnect, String? tag}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: const Color(0xFF101A2A),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF20344E))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 46, height: 46,
            decoration: BoxDecoration(color: const Color(0xFF12345A), borderRadius: BorderRadius.circular(13)),
            child: Icon(icon, color: const Color(0xFF62B2FF), size: 25)),
          const SizedBox(width: 13),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 3),
            Text(subtitle, style: const TextStyle(color: Color(0xFF9BA9BD), fontSize: 12)),
          ])),
          if (tag != null) Chip(label: Text(tag, style: const TextStyle(fontSize: 10)),
            backgroundColor: const Color(0xFF123C70), side: BorderSide.none),
        ]),
        const SizedBox(height: 18),
        content,
        SizedBox(width: double.infinity, child: FilledButton.icon(
          onPressed: _busy ? null : onConnect,
          icon: const Icon(Icons.link), label: const Text('اتصال وتحميل القنوات'),
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF0878E8),
            padding: const EdgeInsets.symmetric(vertical: 14)),
        )),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF05080F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF080D17),
        title: const Row(children: [
          Icon(Icons.dns_rounded, color: Color(0xFF42A5FF)),
          SizedBox(width: 10), Text('ANES TV • السيرفرات'),
        ]),
      ),
      body: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 850),
        child: ListView(padding: const EdgeInsets.all(22), children: [
          Container(padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(gradient: const LinearGradient(
              colors: [Color(0xFF123D70), Color(0xFF101827)]),
              borderRadius: BorderRadius.circular(17)),
            child: Row(children: [
              const Icon(Icons.cloud_done_rounded, size: 34, color: Color(0xFF75BDFF)),
              const SizedBox(width: 13),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('إدارة مصادر البث', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
                const SizedBox(height: 5),
                Text(_status, style: TextStyle(fontSize: 12,
                  color: _status.startsWith('فشل') ? Colors.redAccent : const Color(0xFFB6C9DF))),
              ])),
              if (_busy) const SizedBox(width: 22, height: 22,
                child: CircularProgressIndicator(strokeWidth: 2)),
            ]),
          ),
          const SizedBox(height: 22),
          _serverCard(icon: Icons.account_tree_rounded, title: 'Xtream Codes',
            subtitle: 'اتصل باسم المستخدم وكلمة المرور وعنوان السيرفر',
            tag: 'Xtream',
            content: Column(children: [
              _field('رابط السيرفر / Host', _host, hint: 'http://example.com:8080'),
              _field('اسم المستخدم', _user),
              _field('كلمة المرور', _pass, secret: true),
            ]), onConnect: _connectXtream),
          _serverCard(icon: Icons.insert_drive_file_rounded, title: 'ملف M3U',
            subtitle: 'اختيار ملف قائمة قنوات من الهاتف أو جهاز التلفاز',
            content: SizedBox(width: double.infinity, child: OutlinedButton.icon(
              onPressed: _busy ? null : _pickM3u,
              icon: const Icon(Icons.folder_open), label: const Text('اختيار ملف M3U / M3U8'),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(15)),
            )), onConnect: _pickM3u),
          _serverCard(icon: Icons.link_rounded, title: 'رابط M3U',
            subtitle: 'تحميل قائمة القنوات مباشرة من رابط',
            content: _field('رابط M3U', _m3u, hint: 'https://example.com/playlist.m3u'),
            onConnect: _connectM3u),
          _serverCard(icon: Icons.cloud_sync_rounded, title: 'السيرفر الأونلاين • GitHub',
            subtitle: 'قراءة xtream_config.json من GitHub ثم الاتصال بخادم Xtream',
            tag: 'Online',
            content: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _field('رابط GitHub Raw لملف JSON', _github,
                hint: 'https://raw.githubusercontent.com/USER/REPO/main/xtream_config.json'),
              const Text('يجب أن يحتوي JSON على status: active ومصفوفة xtream_servers. استخدم رابط Raw، ولا تضع رمز وصول GitHub داخل التطبيق.',
                style: TextStyle(color: Color(0xFF8294AA), fontSize: 11)),
              const SizedBox(height: 8),
            ]),
            onConnect: _connectGithub),
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: _busy ? null : () {
                if (_lastSource == 'github') _connectGithub();
                else if (_lastSource == 'xtream') _connectXtream();
                else if (_lastSource == 'm3u_url') _connectM3u();
                else _pickM3u();
              },
              icon: const Icon(Icons.refresh), label: const Text('إعادة تحميل آخر سيرفر'),
            )),
            const SizedBox(width: 10),
            Expanded(child: FilledButton.icon(
              onPressed: _busy ? null : () {
                if (_lastSource == 'github') _connectGithub();
                else if (_lastSource == 'xtream') _connectXtream();
                else if (_lastSource == 'm3u_url') _connectM3u();
                else _pickM3u();
              },
              icon: const Icon(Icons.power_settings_new), label: const Text('اتصال'),
            )),
          ]),
          const SizedBox(height: 20),
          const Text('ملاحظة: GitHub يزوّد التطبيق بإعدادات الاتصال فقط؛ البث يأتي من خادم Xtream. لا تحفظ بيانات اعتماد حقيقية في مستودع عام.',
            style: TextStyle(color: Color(0xFF75869C), fontSize: 11)),
        ]),
      )),
    );
  }
}
