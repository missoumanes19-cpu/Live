import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import '../services/errors.dart';
import '../services/iptv_service.dart';
import '../services/server_connector.dart';
import '../state/app_settings.dart';
import 'server_screen.dart';
import '../widgets/art.dart';

/// إدارة عدة سيرفرات: عرض، تسمية، اختبار الحالة والاشتراك، اتصال، حذف
class ServersScreen extends StatefulWidget {
  final OnConnected onConnected;
  const ServersScreen({super.key, required this.onConnected});
  @override
  State<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends State<ServersScreen> {
  bool _busy = false;
  final Map<int, String> _status = {}; // نتيجة آخر اختبار لكل سيرفر

  Future<void> _connect(Map p) async {
    setState(() => _busy = true);
    try {
      final ch = await context.read<ServerConnector>().connectProfile(p);
      if (!mounted) return;
      widget.onConnected(ch, '${p['name']}');
      Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  Future<void> _test(int i, Map p) async {
    setState(() => _status[i] = '…');
    try {
      if (p['type'] == 'xtream') {
        final d = await context.read<IptvService>()
            .accountInfo(ServerConnector.normalHost('${p['host']}'), '${p['user']}', '${p['pass'] ?? ''}');
        final u = (d['user_info'] is Map) ? Map<String, dynamic>.from(d['user_info'] as Map) : <String, dynamic>{};
        final auth = '${u['auth']}' == '1';
        final exp = int.tryParse('${u['exp_date'] ?? ''}');
        final expText = exp == null ? '∞' : DateTime.fromMillisecondsSinceEpoch(exp * 1000).toString().substring(0, 10);
        final expired = exp != null && DateTime.fromMillisecondsSinceEpoch(exp * 1000).isBefore(DateTime.now());
        final cons = '${u['active_cons'] ?? '?'}/${u['max_connections'] ?? '?'}';
        final head = !auth ? '❌ ${t('بيانات الدخول خاطئة أو انتهى الاشتراك')}'
            : expired ? '⚠️ ${t('منتهي')}' : '✅ ${t('فعّال')}';
        _status[i] = '$head • ${t('ينتهي')}: $expText • ${t('الاتصالات')}: $cons • ${d['_ms']} ms';
      } else {
        final sw = Stopwatch()..start();
        final r = await context.read<IptvService>().probeUrl('${p['url']}');
        sw.stop();
        _status[i] = r ? '✅ ${t('يعمل')} • ${sw.elapsedMilliseconds} ms' : '❌ ${t('فشل')}';
      }
    } catch (e) {
      _status[i] = '❌ ${friendlyError(e)}';
    }
    if (mounted) setState(() {});
  }

  Future<void> _rename(int i, Map p) async {
    final c = TextEditingController(text: '${p['name']}');
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
      backgroundColor: const Color(0xFF101A2A),
      title: Text(t('إعادة تسمية')),
      content: TextField(controller: c, autofocus: true, decoration: InputDecoration(labelText: t('الاسم'))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: Text(t('إلغاء'))),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(t('موافق'))),
      ]));
    if (ok == true && mounted) {
      await context.read<ServerConnector>().renameProfile(i, c.text);
      if (mounted) setState(() {});
    }
  }

  Future<void> _delete(int i, Map p) async {
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
      backgroundColor: const Color(0xFF101A2A),
      title: Text(t('حذف')), content: Text('${p['name']}'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: Text(t('إلغاء'))),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(t('حذف'))),
      ]));
    if (ok == true && mounted) {
      await context.read<ServerConnector>().deleteProfile(i);
      _status.clear();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final conn = context.read<ServerConnector>();
    final profiles = conn.profiles;
    final activeName = Hive.box('settings').get('last_server_name') as String?;
    return Scaffold(
      backgroundColor: const Color(0xFF05080F),
      appBar: AppBar(backgroundColor: const Color(0xFF080D17), title: Text(t('إدارة السيرفرات'), style: const TextStyle(fontSize: 16))),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add, size: 20), label: Text(t('إضافة سيرفر'), style: const TextStyle(fontSize: 13)),
        onPressed: () => Navigator.push(context, MaterialPageRoute(
          builder: (_) => ServerScreen(onConnected: widget.onConnected))).then((_) { if (mounted) setState(() {}); })),
      body: Column(children: [
        if (_busy) const LinearProgressIndicator(),
        Expanded(child: profiles.isEmpty
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 190, height: 130, child: Stack(alignment: Alignment.center, children: [
                const Positioned.fill(child: CustomPaint(painter: WavesPainter(Color(0xFF75BDFF)))),
                gradientBadge(Icons.dns_rounded, kBlueGrad, size: 58),
              ])),
              const SizedBox(height: 6),
              Text(t('لا توجد سيرفرات محفوظة'), style: const TextStyle(color: Colors.white54, fontSize: 13)),
            ]))
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 90),
              itemCount: profiles.length,
              itemBuilder: (_, i) {
                final p = profiles[i];
                final active = conn.isActiveProfile(p) || (p['type'] != 'xtream' && activeName == '${p['name']}');
                return Card(
                  color: const Color(0xFF101A2A),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: active ? const Color(0xFF2E9E6B) : Colors.transparent)),
                  child: Padding(padding: const EdgeInsets.fromLTRB(12, 8, 4, 8), child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        gradientBadge(p['type'] == 'xtream' ? Icons.account_tree_rounded : Icons.link_rounded,
                          p['type'] == 'xtream' ? kBlueGrad : kTealGrad, size: 34),
                        const SizedBox(width: 10),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Flexible(child: Text('${p['name']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                            if (active) Container(margin: const EdgeInsetsDirectional.only(start: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(color: const Color(0xFF2E9E6B), borderRadius: BorderRadius.circular(6)),
                              child: Text(t('نشط'), style: const TextStyle(fontSize: 10))),
                          ]),
                          Text('${p['user'] ?? p['url'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, color: Colors.white54)),
                        ])),
                        IconButton(icon: const Icon(Icons.play_circle_fill_rounded, color: Color(0xFF42A5FF)),
                          tooltip: t('اتصال'), onPressed: _busy ? null : () => _connect(p)),
                        IconButton(icon: const Icon(Icons.network_check_rounded), tooltip: t('اختبار'),
                          onPressed: _busy ? null : () => _test(i, p)),
                        PopupMenuButton<String>(
                          onSelected: (v) { if (v == 'r') { _rename(i, p); } else { _delete(i, p); } },
                          itemBuilder: (_) => [
                            PopupMenuItem(value: 'r', child: Text(t('إعادة تسمية'))),
                            PopupMenuItem(value: 'd', child: Text(t('حذف'))),
                          ]),
                      ]),
                      if (_status[i] != null) Padding(padding: const EdgeInsets.only(top: 4, right: 8),
                        child: Text(_status[i]!, style: const TextStyle(fontSize: 11, color: Color(0xFF9BE3BE)))),
                    ])));
              })),
      ]),
    );
  }
}
