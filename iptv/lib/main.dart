import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'screens/server_screen.dart';
import 'config.dart';
import 'state/library_state.dart';
import 'services/iptv_service.dart';
import 'services/parental_control.dart';
import 'widgets/tv_widgets.dart';
import 'screens/player_screen.dart';
import 'screens/settings_screen.dart';
import 'state/app_settings.dart';
import 'services/server_connector.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await Hive.initFlutter();
  for (final b in ['cache', 'favorites', 'history', 'positions', 'settings']) {
    await Hive.openBox(b);
  }
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  runApp(MultiProvider(providers: [
    ChangeNotifierProvider(create: (_) => AppSettings()),
    ChangeNotifierProvider(create: (_) => LibraryState()),
    ChangeNotifierProvider(create: (_) => ParentalControl()),
    Provider(create: (_) => IptvService()),
    Provider(create: (ctx) => ServerConnector(ctx.read<IptvService>())),
  ], child: const App()));
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark, useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFF05080F),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF168BFF), brightness: Brightness.dark),
      fontFamily: 'Roboto',
    ),
    home: const TvApp(child: Home()),
  );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  List<Channel> _all = [];
  bool _loading = false;
  String? _error;
  String _section = 'البث المباشر';
  String _category = 'الكل';
  String _query = '';
  Channel? _selected;
  final _search = TextEditingController();
  final _url = TextEditingController();
  Box get _settings => Hive.box('settings');

  Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _url.text = _settings.get('m3u_url', defaultValue: '') as String;
    _restoreSavedServer();
    _syncTimer = Timer.periodic(AppConfig.syncInterval, (_) => _autoSync());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _autoSync();
  }

  /// يتحقق من ملف GitHub؛ إن تغيّر يعيد تحميل القنوات تلقائياً
  Future<void> _autoSync() async {
    if (!mounted) return;
    final settings = context.read<AppSettings>();
    final connector = context.read<ServerConnector>();
    final type = _settings.get('server_type') as String?;
    if (!settings.autoSync || connector.configUrl.isEmpty || (type != null && type != 'github')) return;
    try {
      if (!await connector.configChanged() || !mounted) return;
      final data = await connector.syncGithub();
      if (!mounted) return;
      setState(() { _all = data; _selected = data.isEmpty ? null : data.first; _error = null; });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('تم تحديث القنوات من GitHub'))));
    } catch (_) {}
  }

  Future<void> _restoreSavedServer() async {
    final connector = context.read<ServerConnector>();
    final type = (_settings.get('server_type') as String?) ??
        (connector.configUrl.isNotEmpty ? 'github' : 'm3u_url');
    try {
      List<Channel>? data;
      if (type == 'github') {
        setState(() { _loading = true; _error = null; });
        data = await connector.syncGithub();
      } else if (type == 'xtream') {
        var host = (_settings.get('xt_host', defaultValue: '') as String).trim();
        final user = _settings.get('xt_user', defaultValue: '') as String;
        final pass = _settings.get('xt_pass', defaultValue: '') as String;
        if (host.isNotEmpty && user.isNotEmpty) {
          if (!host.startsWith('http://') && !host.startsWith('https://')) host = 'http://$host';
          if (host.endsWith('/')) host = host.substring(0, host.length - 1);
          setState(() { _loading = true; _error = null; });
          data = await context.read<IptvService>().streams(host, user, pass, 'live');
        }
      } else if (type == 'm3u_file') {
        data = connector.savedFileChannels();
      } else if (_url.text.isNotEmpty) {
        _load();
        return;
      }
      if (data != null && mounted) {
        final list = data;
        setState(() { _all = list; _selected = list.isEmpty ? null : list.first; _loading = false; });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncTimer?.cancel();
    _search.dispose(); _url.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_url.text.trim().isEmpty) { _configure(); return; }
    setState(() { _loading = true; _error = null; });
    try {
      final data = await context.read<IptvService>().loadM3u(_url.text.trim(), force: true);
      if (!mounted) return;
      setState(() { _all = data; _selected = data.isEmpty ? null : data.first; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _loadXtreamKind(String kind) async {
    if (!['xtream', 'github'].contains(_settings.get('server_type')) || (_settings.get('xt_host', defaultValue: '') as String).isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الأفلام والمسلسلات تتطلب تسجيل دخول Xtream Codes')));
      setState(() => _section = 'السيرفر');
      return;
    }
    setState(() { _loading = true; _error = null; _section = kind == 'vod' ? 'الأفلام' : kind == 'series' ? 'المسلسلات' : 'البث المباشر'; _category = 'الكل'; });
    try {
      var host = (_settings.get('xt_host', defaultValue: '') as String).trim();
      final user = _settings.get('xt_user', defaultValue: '') as String;
      final pass = _settings.get('xt_pass', defaultValue: '') as String;
      if (!host.startsWith('http://') && !host.startsWith('https://')) host = 'http://$host';
      if (host.endsWith('/')) host = host.substring(0, host.length - 1);
      final data = await context.read<IptvService>().streams(host, user, pass, kind, force: true);
      if (!mounted) return;
      setState(() { _all = data; _selected = data.isEmpty ? null : data.first; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _openSeries(Channel series) async {
    try {
      var host = (_settings.get('xt_host', defaultValue: '') as String).trim();
      final user = _settings.get('xt_user', defaultValue: '') as String;
      final pass = _settings.get('xt_pass', defaultValue: '') as String;
      if (!host.startsWith('http://') && !host.startsWith('https://')) host = 'http://$host';
      if (host.endsWith('/')) host = host.substring(0, host.length - 1);
      final episodes = await context.read<IptvService>().seriesEpisodes(host, user, pass, series);
      if (!mounted) return;
      if (episodes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('لا توجد حلقات متاحة لهذا المسلسل')));
        return;
      }
      await showDialog(context: context, builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF101A2A),
        title: Text(series.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: SizedBox(width: 560, height: 420, child: ListView.separated(
          itemCount: episodes.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) => ListTile(
            leading: const Icon(Icons.play_circle_outline, color: Color(0xFF42A5FF)),
            title: Text(episodes[i].name), subtitle: Text(episodes[i].group),
            onTap: () { Navigator.pop(dialogContext); _playEpisode(episodes[i]); },
          ),
        )),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إغلاق'))],
      ));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر تحميل الحلقات: $e')));
    }
  }

  void _playEpisode(Channel episode) => Navigator.push(context, MaterialPageRoute(
    builder: (_) => PlayerScreen(channel: episode, isLive: false)));

  Future<void> _configure() async {
    _url.text = _settings.get('m3u_url', defaultValue: '') as String;
    await showDialog(context: context, builder: (d) => AlertDialog(
      backgroundColor: const Color(0xFF111A2A),
      title: const Text('إعداد قائمة القنوات'),
      content: SizedBox(width: 520, child: TextField(
        controller: _url, autofocus: true,
        decoration: const InputDecoration(
          labelText: 'رابط M3U', hintText: 'https://example.com/playlist.m3u',
          prefixIcon: Icon(Icons.link), border: OutlineInputBorder(),
        ),
      )),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('إلغاء')),
        FilledButton(onPressed: () async {
          await _settings.put('m3u_url', _url.text.trim());
          if (d.mounted) Navigator.pop(d);
          _load();
        }, child: const Text('حفظ وتشغيل')),
      ],
    ));
  }

  List<String> get _categories {
    final set = _all.map((e) => e.group.trim().isEmpty ? 'أخرى' : e.group.trim()).toSet().toList()..sort();
    return ['الكل', ...set];
  }

  List<Channel> get _visible {
    Iterable<Channel> list = _all;
    if (_section == 'المفضلة') list = context.watch<LibraryState>().favorites;
    if (_section == 'مشاهدة لاحقاً') list = context.watch<LibraryState>().history;
    if (_category != 'الكل' && !['المفضلة', 'مشاهدة لاحقاً'].contains(_section)) list = list.where((c) => c.group == _category);
    if (_query.isNotEmpty) list = list.where((c) => c.name.toLowerCase().contains(_query.toLowerCase()));
    return list.toList();
  }

  void _play(Channel c) {
    if (_section == 'المسلسلات') { _openSeries(c); return; }
    Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(channel: c, isLive: _section == 'البث المباشر')));
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppSettings>();
    final items = _visible;
    return Scaffold(
      body: SafeArea(child: Row(children: [
        _NavigationRail(section: _section, onSelect: (s) {
          if (s == 'السيرفر') {
            Navigator.push(context, MaterialPageRoute(builder: (_) => ServerScreen(
              onConnected: (channels, label) {
                if (!mounted) return;
                setState(() {
                  _all = channels;
                  _selected = channels.isEmpty ? null : channels.first;
                  _section = 'البث المباشر';
                  _category = 'الكل';
                  _error = null;
                });
              },
            )));
          } else if (s == 'الإعدادات') {
            Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen(
              categories: _categories.where((c) => c != 'الكل').toList()))).then((_) { if (mounted) setState(() {}); });
          } else if (s == 'الأفلام') {
            _loadXtreamKind('vod');
          } else if (s == 'المسلسلات') {
            _loadXtreamKind('series');
          } else if (s == 'البث المباشر') {
            setState(() { _section = s; _category = 'الكل'; });
            if (['xtream', 'github'].contains(_settings.get('server_type')) && (_settings.get('xt_host', defaultValue: '') as String).isNotEmpty) _loadXtreamKind('live');
          } else {
            setState(() { _section = s; _category = 'الكل'; });
          }
        }),
        Expanded(child: Column(children: [
          _TopBar(query: _query, controller: _search, onChanged: (v) => setState(() => _query = v),
            onSettings: _configure, count: _all.length),
          Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null ? _Message(icon: Icons.wifi_off, title: 'تعذر تحميل القائمة', detail: _error!, action: _configure)
            : _all.isEmpty ? _Message(icon: Icons.live_tv, title: 'مرحباً بك في ANES TV', detail: 'افتح السيرفر وسجّل بيانات Xtream أو أضف قائمة M3U.', action: _configure)
            : _section == 'البث المباشر'
              ? _LiveDashboard(all: items, categories: _categories, selectedCategory: _category,
                  selected: _selected, onCategory: (v) => setState(() => _category = v),
                  onSelect: (c) => setState(() => _selected = c), onPlay: _play)
              : _LibraryDashboard(title: _section, items: items, categories: _categories, selectedCategory: _category, onCategory: (v) => setState(() => _category = v), onPlay: _play)),
        ])),
      ])),
    );
  }
}

class _NavigationRail extends StatelessWidget {
  final String section; final ValueChanged<String> onSelect;
  const _NavigationRail({required this.section, required this.onSelect});
  @override
  Widget build(BuildContext context) {
    final entries = [
      ('السيرفر', Icons.dns_rounded),
      ('البث المباشر', Icons.live_tv_rounded),
      ('الأفلام', Icons.movie_rounded), ('المسلسلات', Icons.video_library_rounded),
      ('المفضلة', Icons.star_rounded),
      ('مشاهدة لاحقاً', Icons.history_rounded),
    ];
    return Container(width: 104, decoration: const BoxDecoration(
      color: Color(0xFF080D17), border: Border(right: BorderSide(color: Color(0xFF17263B)))),
      child: Column(children: [
        const SizedBox(height: 22),
        Container(width: 54, height: 54, decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF168BFF), Color(0xFF0752B8)]),
          borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: const Color(0xFF168BFF).withAlpha(76), blurRadius: 18)]),
          child: const Icon(Icons.play_arrow_rounded, size: 38, color: Colors.white)),
        const SizedBox(height: 34),
        for (final e in entries) Padding(padding: const EdgeInsets.symmetric(vertical: 7), child:
          _RailItem(icon: e.$2, label: e.$1, selected: section == e.$1, onTap: () => onSelect(e.$1))),
        const Spacer(),
        _RailItem(icon: Icons.settings_rounded, label: 'الإعدادات', selected: false, onTap: () => onSelect('الإعدادات')),
        const SizedBox(height: 22),
      ]),
    );
  }
}

class _RailItem extends StatelessWidget {
  final IconData icon; final String label; final bool selected; final VoidCallback onTap;
  const _RailItem({required this.icon, required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(14), child: AnimatedContainer(
      duration: const Duration(milliseconds: 160), width: 82, padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(color: selected ? const Color(0xFF123C70) : Colors.transparent,
        borderRadius: BorderRadius.circular(14), border: selected ? Border.all(color: const Color(0xFF168BFF), width: 1.4) : null,
        boxShadow: selected ? [BoxShadow(color: const Color(0xFF168BFF).withAlpha(46), blurRadius: 14)] : []),
      child: Column(children: [Icon(icon, size: 25, color: selected ? Colors.white : const Color(0xFF9BA9BD)),
        const SizedBox(height: 5), Text(t(label), maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10, color: selected ? Colors.white : const Color(0xFF9BA9BD)))]))),
  );
}

class _TopBar extends StatelessWidget {
  final String query; final TextEditingController controller; final ValueChanged<String> onChanged;
  final VoidCallback onSettings; final int count;
  const _TopBar({required this.query, required this.controller, required this.onChanged, required this.onSettings, required this.count});
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.fromLTRB(28, 18, 28, 12),
    child: Row(children: [
      const Text('ANES', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Color(0xFF42A5FF))),
      const Text(' TV', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700)),
      const SizedBox(width: 20),
      Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: const Color(0xFF102A23), borderRadius: BorderRadius.circular(20)),
        child: Text('$count ${t('قناة')}', style: const TextStyle(color: Color(0xFF65D6A0), fontSize: 12))),
      const Spacer(),
      SizedBox(width: 260, height: 42, child: TextField(controller: controller, onChanged: onChanged,
        style: const TextStyle(fontSize: 13), decoration: InputDecoration(
          hintText: t('ابحث عن محتوى...'), prefixIcon: const Icon(Icons.search, size: 19),
          filled: true, fillColor: const Color(0xFF111A29), contentPadding: EdgeInsets.zero,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)))),
      const SizedBox(width: 12),
      IconButton(onPressed: onSettings, icon: const Icon(Icons.tune_rounded), tooltip: 'إعداد القائمة'),
    ]));
}

class _LiveDashboard extends StatelessWidget {
  final List<Channel> all; final List<String> categories; final String selectedCategory;
  final Channel? selected; final ValueChanged<String> onCategory; final ValueChanged<Channel> onSelect; final ValueChanged<Channel> onPlay;
  const _LiveDashboard({required this.all, required this.categories, required this.selectedCategory, required this.selected,
    required this.onCategory, required this.onSelect, required this.onPlay});
  @override
  Widget build(BuildContext context) {
    final featured = selected;
    final groups = <String, List<Channel>>{};
    for (final c in all) { groups.putIfAbsent(c.group, () => []).add(c); }
    return ListView(padding: const EdgeInsets.fromLTRB(28, 10, 28, 28), children: [
      Row(children: [
        Expanded(child: Container(height: 205, padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFF123D70), Color(0xFF0B1729), Color(0xFF10101C)]),
            borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF23456B))),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
              Row(children: [Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
                const SizedBox(width: 8), const Text('بث مباشر الآن', style: TextStyle(color: Color(0xFF9CCBFF), fontSize: 13))]),
              const SizedBox(height: 12), Text(featured?.name ?? 'اختر قناتك المفضلة',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8), Text(featured?.group ?? 'قنواتك في مكان واحد', style: const TextStyle(color: Color(0xFF9BAFC8))),
              const SizedBox(height: 15), FilledButton.icon(onPressed: featured == null ? null : () => onPlay(featured),
                icon: const Icon(Icons.play_arrow), label: const Text('مشاهدة الآن')),
            ])),
            const SizedBox(width: 20),
            Container(width: 155, height: 155, decoration: BoxDecoration(color: const Color(0xFF081323),
              borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFF24466C))),
              child: featured?.logo.isNotEmpty == true ? ClipRRect(borderRadius: BorderRadius.circular(18),
                child: Image.network(featured!.logo, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.live_tv, size: 60, color: Color(0xFF5BAEFF))))
                : const Icon(Icons.live_tv_rounded, size: 64, color: Color(0xFF5BAEFF))),
          ]))),
        const SizedBox(width: 16),
        Container(width: 205, height: 205, padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(color: const Color(0xFF101827), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFF1C2B40))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.grid_view_rounded, color: Color(0xFF42A5FF), size: 28),
            const Spacer(), Text('${all.length}', style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold)),
            const Text('إجمالي القنوات', style: TextStyle(color: Color(0xFF9BA9BD))),
          ])),
      ]),
      const SizedBox(height: 24),
      const _SectionTitle('التصنيفات', subtitle: 'اختر فئة القنوات'),
      const SizedBox(height: 12),
      SizedBox(height: 42, child: ListView(scrollDirection: Axis.horizontal, children: [
        for (final c in categories) Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(
          label: Text(c), selected: selectedCategory == c, onSelected: (_) => onCategory(c),
          selectedColor: const Color(0xFFFF8A00), backgroundColor: const Color(0xFF111A29),
          labelStyle: TextStyle(color: selectedCategory == c ? Colors.white : const Color(0xFFB5C0D0), fontWeight: FontWeight.w600))),
      ])),
      const SizedBox(height: 22),
      if (selectedCategory != 'الكل') _ChannelRow(title: selectedCategory, channels: all, onSelect: onSelect, onPlay: onPlay)
      else for (final entry in groups.entries.take(8))
        _ChannelRow(title: entry.key, channels: entry.value, onSelect: onSelect, onPlay: onPlay),
      if (all.isEmpty) const Center(child: Padding(padding: EdgeInsets.all(30), child: Text('لا توجد عناصر في هذا التصنيف'))),
    ]);
  }
}

class _ChannelRow extends StatelessWidget {
  final String title; final List<Channel> channels; final ValueChanged<Channel> onSelect; final ValueChanged<Channel> onPlay;
  const _ChannelRow({required this.title, required this.channels, required this.onSelect, required this.onPlay});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _SectionTitle(title, subtitle: '${channels.length} قناة'),
    const SizedBox(height: 12),
    SizedBox(height: 142, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: channels.length,
      separatorBuilder: (_, __) => const SizedBox(width: 12),
      itemBuilder: (_, i) => _ChannelTile(channel: channels[i], onSelect: () => onSelect(channels[i]), onPlay: () => onPlay(channels[i])))),
    const SizedBox(height: 24),
  ]);
}

class _ChannelTile extends StatefulWidget {
  final Channel channel; final VoidCallback onSelect; final VoidCallback onPlay;
  const _ChannelTile({required this.channel, required this.onSelect, required this.onPlay});
  @override
  State<_ChannelTile> createState() => _ChannelTileState();
}
class _ChannelTileState extends State<_ChannelTile> {
  bool focused = false;
  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    onShowFocusHighlight: (v) => setState(() => focused = v),
    child: GestureDetector(onTap: widget.onPlay, child: InkWell(onTap: widget.onSelect, onDoubleTap: widget.onPlay,
      child: AnimatedContainer(duration: const Duration(milliseconds: 140), width: 164, padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: const Color(0xFF111A29), borderRadius: BorderRadius.circular(15),
          border: Border.all(color: focused ? const Color(0xFFFF9200) : const Color(0xFF1D2A3D), width: focused ? 2.5 : 1)),
        child: Row(children: [
          Container(width: 54, height: 54, decoration: BoxDecoration(color: const Color(0xFF091321), borderRadius: BorderRadius.circular(11)),
            child: widget.channel.logo.isNotEmpty ? ClipRRect(borderRadius: BorderRadius.circular(11),
              child: Image.network(widget.channel.logo, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const Icon(Icons.tv)))
              : const Icon(Icons.tv, color: Color(0xFF62B2FF), size: 28)),
          const SizedBox(width: 9), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('${(widget.channel.id.hashCode.abs() % 999 + 1).toString().padLeft(3, '0')}', style: const TextStyle(color: Color(0xFFFFA12B), fontSize: 10)),
            const SizedBox(height: 5), Text(widget.channel.name, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
          ])),
        ]))),
    ),
  );
}

class _LibraryDashboard extends StatelessWidget {
  final String title; final List<Channel> items; final List<String> categories;
  final String selectedCategory; final ValueChanged<String> onCategory;
  final ValueChanged<Channel> onPlay;
  const _LibraryDashboard({required this.title, required this.items, required this.categories,
    required this.selectedCategory, required this.onCategory, required this.onPlay});
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(28), children: [
    _SectionTitle(title, subtitle: '${items.length} عنصر'),
    const SizedBox(height: 16),
    SizedBox(height: 42, child: ListView(scrollDirection: Axis.horizontal, children: [
      for (final c in categories) Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(
        label: Text(c), selected: selectedCategory == c, onSelected: (_) => onCategory(c),
        selectedColor: const Color(0xFFFF8A00), backgroundColor: const Color(0xFF111A29),
        labelStyle: TextStyle(color: selectedCategory == c ? Colors.white : const Color(0xFFB5C0D0)))),
    ])),
    const SizedBox(height: 20),
    if (items.isEmpty) const Center(child: Padding(padding: EdgeInsets.all(35),
      child: Text('لا توجد عناصر في هذا التصنيف', style: TextStyle(color: Color(0xFF9BA9BD)))))
    else Wrap(spacing: 16, runSpacing: 20, children: [for (final c in items)
      _PosterTile(channel: c, onTap: () => onPlay(c))]),
  ]);
}

class _PosterTile extends StatefulWidget {
  final Channel channel; final VoidCallback onTap;
  const _PosterTile({required this.channel, required this.onTap});
  @override
  State<_PosterTile> createState() => _PosterTileState();
}
class _PosterTileState extends State<_PosterTile> {
  bool focused = false;
  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    onShowFocusHighlight: (v) => setState(() => focused = v),
    child: GestureDetector(onTap: widget.onTap, child: AnimatedContainer(
      duration: const Duration(milliseconds: 150), width: 150,
      decoration: BoxDecoration(color: const Color(0xFF101827), borderRadius: BorderRadius.circular(12),
        border: Border.all(color: focused ? const Color(0xFFFF9200) : const Color(0xFF1D2A3D), width: focused ? 2.5 : 1),
        boxShadow: focused ? [BoxShadow(color: const Color(0xFFFF9200).withAlpha(46), blurRadius: 14)] : []),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        SizedBox(height: 195, width: 150, child: widget.channel.logo.isEmpty
          ? const ColoredBox(color: Color(0xFF0A1422), child: Icon(Icons.movie_rounded, size: 48, color: Color(0xFF62B2FF)))
          : Image.network(widget.channel.logo, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const ColoredBox(color: Color(0xFF0A1422), child: Icon(Icons.movie_rounded, size: 48))),
        ),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9), child: Text(
          widget.channel.name, maxLines: 2, overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
      ]),
    )),
  );
}

class _SectionTitle extends StatelessWidget {
  final String title; final String? subtitle;
  const _SectionTitle(this.title, {this.subtitle});
  @override
  Widget build(BuildContext context) => Row(children: [
    Container(width: 4, height: 22, decoration: BoxDecoration(color: const Color(0xFF168BFF), borderRadius: BorderRadius.circular(4))),
    const SizedBox(width: 10), Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
    if (subtitle != null) ...[const SizedBox(width: 10), Text(subtitle!, style: const TextStyle(color: Color(0xFF7F90A8), fontSize: 11))],
  ]);
}

class _Message extends StatelessWidget {
  final IconData icon; final String title, detail; final VoidCallback action;
  const _Message({required this.icon, required this.title, required this.detail, required this.action});
  @override
  Widget build(BuildContext context) => Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 64, color: const Color(0xFF42A5FF)), const SizedBox(height: 18),
      Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      const SizedBox(height: 8), Text(detail, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF9BA9BD))),
      const SizedBox(height: 20), FilledButton.icon(onPressed: action, icon: const Icon(Icons.add_link), label: const Text('إعداد رابط القنوات')),
    ])));
}
