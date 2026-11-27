import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import '../services/iptv_service.dart';
import '../state/app_settings.dart';
import '../widgets/art.dart';

class SearchScreen extends StatefulWidget {
  final List<Channel> fallback; // القائمة الحالية إن لم يكن هناك Xtream
  final void Function(Channel c, String kind) onPick;
  const SearchScreen({super.key, required this.fallback, required this.onPick});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _ctrl = TextEditingController();
  final _items = <(Channel, String)>[];
  List<(Channel, String)> _results = [];
  bool _loading = true;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = Hive.box('settings');
    final host = (b.get('xt_host', defaultValue: '') as String).trim();
    final user = b.get('xt_user', defaultValue: '') as String;
    final pass = b.get('xt_pass', defaultValue: '') as String;
    if (host.isEmpty || user.isEmpty) {
      for (final c in widget.fallback) { _items.add((c, 'live')); }
    } else {
      final svc = context.read<IptvService>();
      for (final kind in ['live', 'vod', 'series']) {
        try {
          final list = await svc.streams(host, user, pass, kind);
          for (final c in list) { _items.add((c, kind)); }
        } catch (_) {}
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      final s = q.trim().toLowerCase();
      setState(() {
        _results = s.isEmpty ? [] : _items.where((e) => e.$1.name.toLowerCase().contains(s)).take(200).toList();
      });
    });
  }

  @override
  void dispose() { _debounce?.cancel(); _ctrl.dispose(); super.dispose(); }

  IconData _icon(String k) => k == 'vod' ? Icons.movie : k == 'series' ? Icons.video_library : Icons.live_tv;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: TextField(controller: _ctrl, autofocus: true, onChanged: _onChanged,
      decoration: InputDecoration(hintText: t('ابحث في القنوات والأفلام والمسلسلات'), border: InputBorder.none))),
    body: _loading ? const Center(child: CircularProgressIndicator())
      : ListView.builder(itemCount: _results.length, itemBuilder: (_, i) {
          final (c, kind) = _results[i];
          return ListTile(leading: Icon(_icon(kind), color: kAccent3),
            title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(c.group, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () { Navigator.pop(context); widget.onPick(c, kind); });
        }),
  );
}
