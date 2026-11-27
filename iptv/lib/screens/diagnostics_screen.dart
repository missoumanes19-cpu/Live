import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import '../config.dart';
import '../services/epg_service.dart';
import '../services/iptv_service.dart';
import '../state/app_settings.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});
  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  Map<String, dynamic>? _info;
  String? _error;
  bool _busy = false;

  @override
  void initState() { super.initState(); _run(); }

  Future<void> _run() async {
    final b = Hive.box('settings');
    final host = (b.get('xt_host', defaultValue: '') as String).trim();
    final user = b.get('xt_user', defaultValue: '') as String;
    final pass = b.get('xt_pass', defaultValue: '') as String;
    if (host.isEmpty || user.isEmpty) {
      setState(() { _error = 'لا يوجد سيرفر Xtream'; _info = null; });
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final d = await context.read<IptvService>().accountInfo(host, user, pass);
      if (mounted) setState(() { _info = d; _busy = false; });
    } catch (e) {
      if (mounted) setState(() { _error = '$e'; _busy = false; });
    }
  }

  Widget _row(String k, String v, {bool bad = false}) => ListTile(dense: true,
    title: Text(k, style: const TextStyle(color: Color(0xFF9BA9BD), fontSize: 13)),
    trailing: Text(v, style: TextStyle(fontWeight: FontWeight.w600,
      color: bad ? Colors.redAccent : Colors.white)));

  @override
  Widget build(BuildContext context) {
    final epg = context.watch<EpgService>();
    final u = (_info?['user_info'] is Map) ? Map<String, dynamic>.from(_info!['user_info'] as Map) : <String, dynamic>{};
    final exp = int.tryParse('${u['exp_date'] ?? ''}');
    final expText = exp == null ? t('غير محدود')
        : DateTime.fromMillisecondsSinceEpoch(exp * 1000).toString().substring(0, 10);
    final active = '${u['status'] ?? ''}'.toLowerCase() == 'active';
    return Scaffold(
      appBar: AppBar(title: Text(t('تشخيص الاتصال')), actions: [
        IconButton(icon: const Icon(Icons.refresh), tooltip: t('اختبار'), onPressed: _busy ? null : _run)]),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) Padding(padding: const EdgeInsets.all(12),
            child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
          if (_info != null) ...[
            _row(t('زمن الاستجابة'), '${_info!['_ms']} ms', bad: (_info!['_ms'] as int) > 3000),
            _row(t('حالة الحساب'), '${u['status'] ?? '-'}', bad: !active),
            _row(t('تاريخ الانتهاء'), expText),
            _row(t('الاتصالات المتزامنة'), '${u['active_cons'] ?? '-'} / ${u['max_connections'] ?? '-'}'),
          ],
          const Divider(),
          _row('EPG', epg.loading ? '...' : epg.error != null ? 'ERROR' : '${epg.count}', bad: epg.error != null),
          _row(t('وضع فك التشفير'), context.read<AppSettings>().decoder),
          _row(t('الإصدار'), AppConfig.version),
        ]))),
    );
  }
}
