import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'screens/server_screen.dart';
import 'config.dart';
import 'state/library_state.dart';
import 'services/download_manager.dart';
import 'services/iptv_service.dart';
import 'services/parental_control.dart';
import 'widgets/tv_widgets.dart';
import 'screens/settings_screen.dart';
import 'screens/classic_ui.dart';
import 'services/player_launcher.dart';
import 'services/errors.dart';
import 'state/app_settings.dart';
import 'services/server_connector.dart';
import 'services/epg_service.dart';
import 'screens/search_screen.dart';

/// يحفظ سبب فشل تهيئة المشغّل (إن حدث) ليُعرض للمستخدم
String? kMediaKitError;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // التطبيق يعمل بشكل أفقي وبملء الشاشة
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  PaintingBinding.instance.imageCache.maximumSizeBytes = 120 << 20;
  PaintingBinding.instance.imageCache.maximumSize = 600;

  // أي خطأ أثناء البناء يظهر كنص بدل شاشة رمادية
  ErrorWidget.builder = (d) => Material(
        color: const Color(0xFF05080F),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
              child: SelectableText(
                '${d.exception}',
                style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              ),
            ),
          ),
        ),
      );

  try {
    try {
      MediaKit.ensureInitialized();
    } catch (e) {
      kMediaKitError = '$e';
    }

    await Hive.initFlutter().timeout(const Duration(seconds: 15));
    for (final b in ['cache', 'favorites', 'history', 'positions', 'settings', 'downloads']) {
      try {
        await Hive.openBox(b).timeout(const Duration(seconds: 15));
      } catch (_) {
        // ملف تالف: احذفه وأعد إنشاءه
        await Hive.deleteBoxFromDisk(b);
        await Hive.openBox(b);
      }
    }

    applyPerformanceMode(Hive.box('settings').get('lite', defaultValue: false) as bool);

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AppSettings()),
          ChangeNotifierProvider(create: (_) => LibraryState()),
          ChangeNotifierProvider(create: (_) => ParentalControl()),
          ChangeNotifierProvider(create: (_) => EpgService()),
          ChangeNotifierProvider(create: (_) => DownloadManager()..init()),
          Provider(create: (_) => IptvService()),
          Provider(create: (ctx) => ServerConnector(ctx.read<IptvService>())),
        ],
        child: const App(),
      ),
    );
  } catch (e, st) {
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: SelectableText(
                  'Startup error:\n$e\n\n$st',
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    final lang = context.select<AppSettings, String>((_) => AppSettings.lang);
    final rtl = lang == 'ar';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF05080F),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF168BFF),
          brightness: Brightness.dark,
        ),
        fontFamily: 'Roboto',
      ),
      builder: (ctx, child) => Directionality(
        textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const TvApp(child: Home()),
    );
  }
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
  String _section = 'الرئيسية';
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
    if (kMediaKitError != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (d) => AlertDialog(
            title: const Text('Player init error'),
            content: SingleChildScrollView(child: SelectableText(kMediaKitError!)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d), child: const Text('OK')),
            ],
          ),
        );
      });
    }
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
    if (!settings.autoSync || connector.configUrl.isEmpty || (type != null && type != 'github')) {
      return;
    }
    try {
      if (!await connector.configChanged() || !mounted) return;
      final data = await connector.syncGithub();
      if (!mounted) return;
      setState(() {
        _all = data;
        _selected = data.isEmpty ? null : data.first;
        _error = null;
      });
      _loadEpg();
      _showNotices(connector.lastConfig);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('تم تحديث القنوات من السيرفر'))),
        );
      }
    } catch (_) {}
  }

  String _normalizedHost() {
    var host = (_settings.get('xt_host', defaultValue: '') as String).trim();
    if (host.isEmpty) return '';
    if (!host.startsWith('http://') && !host.startsWith('https://')) {
      host = 'http://$host';
    }
    if (host.endsWith('/')) {
      host = host.substring(0, host.length - 1);
    }
    return host;
  }

  Future<void> _restoreSavedServer() async {
    final connector = context.read<ServerConnector>();
    final type = (_settings.get('server_type') as String?) ??
        (connector.configUrl.isNotEmpty ? 'github' : 'm3u_url');
    if (type == 'none') return;
    try {
      List<Channel>? data;
      if (type == 'github') {
        setState(() {
          _loading = true;
          _error = null;
        });
        data = await connector.syncGithub();
      } else if (type == 'xtream') {
        final host = _normalizedHost();
        final user = _settings.get('xt_user', defaultValue: '') as String;
        final pass = _settings.get('xt_pass', defaultValue: '') as String;
        if (host.isNotEmpty && user.isNotEmpty) {
          setState(() {
            _loading = true;
            _error = null;
          });
          data = await context.read<IptvService>().streams(host, user, pass, 'live');
        }
      } else if (type == 'm3u_file') {
        data = connector.savedFileChannels();
      } else if (_url.text.isNotEmpty) {
        await _load();
        return;
      }
      if (data != null && mounted) {
        final list = data;
        setState(() {
          _all = list;
          _selected = list.isEmpty ? null : list.first;
          _loading = false;
        });
        _loadEpg();
        if (type == 'github') _showNotices(connector.lastConfig);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendlyError(e);
          _loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _syncTimer?.cancel();
    _search.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_url.text.trim().isEmpty) {
      _configure();
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await context.read<IptvService>().loadM3u(_url.text.trim(), force: true);
      if (!mounted) return;
      setState(() {
        _all = data;
        _selected = data.isEmpty ? null : data.first;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  Future<void> _loadXtreamKind(String kind) async {
    final host = _normalizedHost();
    if (!['xtream', 'github'].contains(_settings.get('server_type')) || host.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الأفلام والمسلسلات تتطلب تسجيل دخول Xtream Codes')),
        );
      }
      setState(() => _section = 'السيرفر');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _section = kind == 'vod'
          ? 'الأفلام'
          : kind == 'series'
              ? 'المسلسلات'
              : 'البث المباشر';
      _category = 'الكل';
    });
    try {
      final user = _settings.get('xt_user', defaultValue: '') as String;
      final pass = _settings.get('xt_pass', defaultValue: '') as String;
      final data = await context.read<IptvService>().streams(host, user, pass, kind, force: true);
      if (!mounted) return;
      setState(() {
        _all = data;
        _selected = data.isEmpty ? null : data.first;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendlyError(e);
          _loading = false;
        });
      }
    }
  }

  Future<void> _openSeries(Channel series) async {
    try {
      final host = _normalizedHost();
      final user = _settings.get('xt_user', defaultValue: '') as String;
      final pass = _settings.get('xt_pass', defaultValue: '') as String;
      final episodes = await context.read<IptvService>().seriesEpisodes(host, user, pass, series);
      if (!mounted) return;
      if (episodes.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا توجد حلقات متاحة لهذا المسلسل')),
        );
        return;
      }
      await showDialog(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: const Color(0xFF101A2A),
          title: Text(series.name, maxLines: 2, overflow: TextOverflow.ellipsis),
          content: SizedBox(
            width: 560,
            height: 420,
            child: ListView.separated(
              itemCount: episodes.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) => ListTile(
                leading: const Icon(Icons.play_circle_outline, color: Color(0xFF42A5FF)),
                title: Text(episodes[i].name),
                subtitle: Text(episodes[i].group),
                trailing: IconButton(
                  icon: const Icon(Icons.download_rounded),
                  tooltip: t('تحميل'),
                  onPressed: () => _downloadEpisodes(series, [episodes[i]]),
                ),
                onTap: () {
                  Navigator.pop(dialogContext);
                  _playEpisode(episodes[i]);
                },
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => _downloadEpisodes(series, episodes),
              child: Text(t('تحميل الكل')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تحميل الحلقات: $e')),
        );
      }
    }
  }

  void _playEpisode(Channel episode) {
    openPlayer(context, episode, live: false);
  }

  Future<void> _downloadEpisodes(Channel series, List<Channel> eps) async {
    final dm = context.read<DownloadManager>();
    var started = 0;
    for (final e in eps) {
      final named = Channel.fromMap({
        ...e.toMap(),
        'name': '${series.name} - ${e.name}',
        'logo': e.logo.isEmpty ? series.logo : e.logo,
      });
      if (await dm.enqueue(named)) started++;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          started > 0 ? '${t('بدأ التحميل')} ($started)' : t('هذا الرابط لا يدعم التحميل'),
        ),
      ),
    );
  }

  Future<void> _configure() async {
    _url.text = _settings.get('m3u_url', defaultValue: '') as String;
    await showDialog(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: const Color(0xFF111A2A),
        title: const Text('إعداد قائمة القنوات'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: _url,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'رابط M3U',
              hintText: 'https://example.com/playlist.m3u',
              prefixIcon: Icon(Icons.link),
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () async {
              await _settings.put('m3u_url', _url.text.trim());
              if (d.mounted) Navigator.pop(d);
              _load();
            },
            child: const Text('حفظ وتشغيل'),
          ),
        ],
      ),
    );
  }

  List<Channel> get _base {
    final hidden = context.read<AppSettings>().hidden;
    return hidden.isEmpty ? _all : _all.where((c) => !hidden.contains(c.group)).toList();
  }

  List<String> get _allCategories =>
      (_all.map((e) => e.group.trim().isEmpty ? 'أخرى' : e.group.trim()).toSet().toList()..sort());

  List<String> get _categories {
    final set = _base.map((e) => e.group.trim().isEmpty ? 'أخرى' : e.group.trim()).toSet().toList()..sort();
    return ['الكل', ...set];
  }

  List<Channel> get _visible {
    Iterable<Channel> list = _base;
    if (_section == 'المفضلة' || _category == '__fav') {
      list = context.read<LibraryState>().favorites;
    }
    if (_section == 'مشاهدة لاحقاً' || _category == '__recent') {
      list = context.read<LibraryState>().history;
    }
    final special = ['__fav', '__recent'].contains(_category) ||
        ['المفضلة', 'مشاهدة لاحقاً'].contains(_section);
    if (_category != 'الكل' && !special) {
      list = list.where((c) => c.group == _category);
    }
    if (_query.isNotEmpty) {
      list = list.where((c) => c.name.toLowerCase().contains(_query.toLowerCase()));
    }
    return list.toList();
  }

  void _openServerScreen() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ServerScreen(
          onConnected: (channels, label) {
            if (!mounted) return;
            setState(() {
              _all = channels;
              _selected = channels.isEmpty ? null : channels.first;
              _section = channels.isEmpty ? 'الرئيسية' : 'البث المباشر';
              _category = 'الكل';
              _error = null;
            });
            _loadEpg();
          },
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SettingsScreen(categories: _allCategories)),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  bool get _hasXtream =>
      ['xtream', 'github'].contains(_settings.get('server_type')) &&
      (_settings.get('xt_host', defaultValue: '') as String).trim().isNotEmpty;

  void _classicSection(String s) {
    if (s == 'الأفلام') {
      _loadXtreamKind('vod');
    } else if (s == 'المسلسلات') {
      _loadXtreamKind('series');
    } else if (s == 'البث المباشر') {
      setState(() {
        _section = s;
        _category = 'الكل';
      });
      if (_hasXtream) _loadXtreamKind('live');
    } else {
      setState(() {
        _section = 'الرئيسية';
        _category = 'الكل';
      });
    }
  }

  Future<void> _reload() async {
    final kind = _section == 'الأفلام'
        ? 'vod'
        : _section == 'المسلسلات'
            ? 'series'
            : 'live';
    if (_hasXtream) {
      await _loadXtreamKind(kind);
    } else if (_settings.get('server_type') == 'github') {
      await _restoreSavedServer();
    } else if (_url.text.isNotEmpty) {
      await _load();
    }
    _loadEpg();
  }

  Widget _classicBuild(List<Channel> items) {
    final counts = <String, int>{'الكل': _base.length};
    for (final c in _base) {
      final g = c.group.trim().isEmpty ? 'أخرى' : c.group.trim();
      counts[g] = (counts[g] ?? 0) + 1;
    }
    return Scaffold(
      body: ClassicHome(
        section: _section,
        items: items,
        categories: _categories,
        counts: counts,
        category: _category,
        selected: _selected,
        loading: _loading,
        error: _error,
        hasData: _all.isNotEmpty,
        search: _search,
        onQuery: (v) => setState(() => _query = v),
        onSection: _classicSection,
        onCategory: _selectCategory,
        onSelect: (c) => setState(() => _selected = c),
        onPlay: _play,
        onServer: _openServerScreen,
        onReload: _reload,
        onSettings: _openSettings,
        onExit: () => SystemNavigator.pop(),
      ),
    );
  }

  Future<void> _selectCategory(String v) async {
    if (v != 'الكل' && !await context.read<ParentalControl>().guard(context, v)) return;
    if (mounted) setState(() => _category = v);
  }

  Future<void> _play(Channel c) async {
    if (!await context.read<ParentalControl>().guard(context, c.group)) return;
    if (!mounted) return;
    if (_section == 'المسلسلات') {
      _openSeries(c);
      return;
    }
    final live = _section == 'البث المباشر' || _section == 'الرئيسية';
    if (live) _settings.put('last_channel', c.toMap());
    await openPlayer(context, c, live: live, playlist: live ? _visible : const <Channel>[]);
  }

  void _pickFromSearch(Channel c, String kind) {
    if (kind == 'series') {
      _openSeries(c);
      return;
    }
    openPlayer(context, c, live: kind == 'live');
  }

  void _openSearch() => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SearchScreen(fallback: _all, onPick: _pickFromSearch),
        ),
      );

  Future<void> _loadEpg() async {
    try {
      var url = (_settings.get('epg_url', defaultValue: '') as String).trim();
      final host = _normalizedHost();
      final user = _settings.get('xt_user', defaultValue: '') as String;
      final pass = _settings.get('xt_pass', defaultValue: '') as String;
      if (url.isEmpty && host.isNotEmpty && user.isNotEmpty) {
        url = context.read<IptvService>().xmltvUrl(host, user, pass);
      }
      if (url.isEmpty) return;
      await Future.delayed(const Duration(seconds: 4));
      if (!mounted) return;
      context.read<EpgService>().load(url);
    } catch (_) {}
  }

  Future<void> _showNotices(GithubConfig? cfg) async {
    if (cfg == null || !mounted) return;
    if (cfg.minVersion.isNotEmpty && ServerConnector.versionLess(AppConfig.version, cfg.minVersion)) {
      await showDialog(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(t('يتوفر تحديث للتطبيق')),
          content: SelectableText(
            cfg.updateUrl.isEmpty ? t('حدّث التطبيق إلى آخر إصدار') : cfg.updateUrl,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('OK')),
          ],
        ),
      );
    }
    if (cfg.message.isNotEmpty && mounted) {
      final h = ServerConnector.hashOf(cfg.message);
      if (_settings.get('github_msg_seen') != h) {
        await _settings.put('github_msg_seen', h);
        if (!mounted) return;
        await showDialog(
          context: context,
          builder: (d) => AlertDialog(
            title: const Text('ANES TV'),
            content: Text(cfg.message),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d), child: const Text('OK')),
            ],
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    context.watch<LibraryState>();
    final items = _visible;
    if (settings.uiStyle == 'classic') return _classicBuild(items);
    final sec = _section == 'الرئيسية' ? 'البث المباشر' : _section;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            _NavigationRail(
              section: sec,
              onSelect: (s) {
                if (s == 'السيرفر') {
                  _openServerScreen();
                } else if (s == 'الإعدادات') {
                  _openSettings();
                } else if (s == 'الأفلام') {
                  _loadXtreamKind('vod');
                } else if (s == 'المسلسلات') {
                  _loadXtreamKind('series');
                } else if (s == 'البث المباشر') {
                  setState(() {
                    _section = s;
                    _category = 'الكل';
                  });
                  if (_hasXtream) _loadXtreamKind('live');
                } else {
                  setState(() {
                    _section = s;
                    _category = 'الكل';
                  });
                }
              },
            ),
            Expanded(
              child: Column(
                children: [
                  _TopBar(
                    query: _query,
                    controller: _search,
                    onChanged: (v) => setState(() => _query = v),
                    onSettings: _configure,
                    onSearchAll: _openSearch,
                    count: _all.length,
                  ),
                  Expanded(
                    child: _loading
                        ? const _SkeletonGrid()
                        : _error != null
                            ? _Message(
                                icon: Icons.wifi_off,
                                title: 'تعذر تحميل القائمة',
                                detail: _error!,
                                action: _configure,
                              )
                            : _all.isEmpty
                                ? _Message(
                                    icon: Icons.live_tv,
                                    title: 'مرحباً بك في ANES TV',
                                    detail: 'افتح السيرفر وسجّل بيانات Xtream أو أضف قائمة M3U.',
                                    action: _configure,
                                  )
                                : sec == 'البث المباشر'
                                    ? _LiveDashboard(
                                        all: items,
                                        categories: _categories,
                                        selectedCategory: _category,
                                        selected: _selected,
                                        onCategory: _selectCategory,
                                        onSelect: (c) => setState(() => _selected = c),
                                        onPlay: _play,
                                      )
                                    : _LibraryDashboard(
                                        title: sec,
                                        items: items,
                                        categories: _categories,
                                        selectedCategory: _category,
                                        onCategory: _selectCategory,
                                        onPlay: _play,
                                      ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavigationRail extends StatelessWidget {
  final String section;
  final ValueChanged<String> onSelect;
  const _NavigationRail({required this.section, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final entries = [
      ('السيرفر', Icons.dns_rounded),
      ('البث المباشر', Icons.live_tv_rounded),
      ('الأفلام', Icons.movie_rounded),
      ('المسلسلات', Icons.video_library_rounded),
      ('المفضلة', Icons.star_rounded),
      ('مشاهدة لاحقاً', Icons.history_rounded),
    ];
    return Container(
      width: 86,
      decoration: const BoxDecoration(
        color: Color(0xFF080D17),
        border: Border(right: BorderSide(color: Color(0xFF17263B))),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset('assets/logo.png', width: 46, height: 46),
            ),
            const SizedBox(height: 14),
            for (final e in entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: _RailItem(
                  icon: e.$2,
                  label: e.$1,
                  selected: section == e.$1,
                  onTap: () => onSelect(e.$1),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: _RailItem(
                icon: Icons.settings_rounded,
                label: 'الإعدادات',
                selected: section == 'الإعدادات',
                onTap: () => onSelect('الإعدادات'),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(11),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 76,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFF123C70) : Colors.transparent,
              borderRadius: BorderRadius.circular(11),
              border: selected
                  ? Border.all(color: const Color(0xFF168BFF), width: 1.2)
                  : null,
            ),
            child: Column(
              children: [
                Icon(icon, size: 21, color: selected ? Colors.white : const Color(0xFF9BA9BD)),
                const SizedBox(height: 3),
                Text(
                  t(label),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9,
                    color: selected ? Colors.white : const Color(0xFF9BA9BD),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

void _favToggle(BuildContext context, Channel c) {
  final lib = context.read<LibraryState>();
  lib.toggleFavorite(c);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      duration: const Duration(seconds: 1),
      content: Text(lib.isFavorite(c.id) ? t('أضيفت إلى المفضلة') : t('أزيلت من المفضلة')),
    ),
  );
}

class _TopBar extends StatelessWidget {
  final String query;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onSettings, onSearchAll;
  final int count;
  const _TopBar({
    required this.query,
    required this.controller,
    required this.onChanged,
    required this.onSettings,
    required this.onSearchAll,
    required this.count,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: Row(
          children: [
            const Text(
              'ANES',
              style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900, color: Color(0xFF42A5FF)),
            ),
            const Text(' TV', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
            const SizedBox(width: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF102A23),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$count ${t('قناة')}',
                style: const TextStyle(color: Color(0xFF65D6A0), fontSize: 12),
              ),
            ),
            const Spacer(),
            SizedBox(
              width: 220,
              height: 38,
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: t('ابحث عن محتوى...'),
                  prefixIcon: const Icon(Icons.search, size: 19),
                  filled: true,
                  fillColor: const Color(0xFF111A29),
                  contentPadding: EdgeInsets.zero,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              onPressed: onSearchAll,
              icon: const Icon(Icons.manage_search_rounded),
              tooltip: t('بحث شامل'),
            ),
            IconButton(
              onPressed: onSettings,
              icon: const Icon(Icons.tune_rounded),
              tooltip: 'إعداد القائمة',
            ),
          ],
        ),
      );
}

class _LiveDashboard extends StatelessWidget {
  final List<Channel> all;
  final List<String> categories;
  final String selectedCategory;
  final Channel? selected;
  final ValueChanged<String> onCategory;
  final ValueChanged<Channel> onSelect;
  final ValueChanged<Channel> onPlay;

  const _LiveDashboard({
    required this.all,
    required this.categories,
    required this.selectedCategory,
    required this.selected,
    required this.onCategory,
    required this.onSelect,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 176,
          margin: const EdgeInsets.fromLTRB(12, 8, 8, 12),
          decoration: BoxDecoration(
            color: const Color(0xFF0C1422),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF1A2A40)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 12, 8, 8),
                child: Row(
                  children: [
                    Icon(Icons.category_rounded, size: 18, color: Color(0xFF42A5FF)),
                    SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        'التصنيفات',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(6),
                  itemCount: categories.length,
                  itemBuilder: (context, i) {
                    final c = categories[i];
                    final active = c == selectedCategory;
                    final count =
                        c == 'الكل' ? all.length : all.where((ch) => ch.group == c).length;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Material(
                        color: active ? const Color(0xFF15365F) : Colors.transparent,
                        borderRadius: BorderRadius.circular(9),
                        child: InkWell(
                          onTap: () => onCategory(c),
                          borderRadius: BorderRadius.circular(9),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 10),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    c,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: active ? Colors.white : const Color(0xFFB3C1D4),
                                      fontWeight: active ? FontWeight.w700 : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                Text(
                                  '$count',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: active ? const Color(0xFF80C4FF) : const Color(0xFF74869D),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        selectedCategory == 'الكل' ? 'القنوات المباشرة' : selectedCategory,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                    ),
                    Text(
                      '${all.length} قناة',
                      style: const TextStyle(color: Color(0xFF8FA3BD), fontSize: 11),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: all.isEmpty
                    ? const Center(child: Text('لا توجد قنوات في هذا التصنيف'))
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final width = constraints.maxWidth;
                          final columns =
                              width >= 1200 ? 5 : width >= 900 ? 4 : width >= 600 ? 3 : 2;
                          return GridView.builder(
                            padding: const EdgeInsets.fromLTRB(10, 4, 14, 14),
                            itemCount: all.length,
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: columns,
                              crossAxisSpacing: 10,
                              mainAxisSpacing: 10,
                              childAspectRatio: width < 500 ? 1.55 : 1.9,
                            ),
                            itemBuilder: (context, index) => _ChannelTile(
                              channel: all[index],
                              selected: selected?.id == all[index].id,
                              onSelect: () => onSelect(all[index]),
                              onPlay: () => onPlay(all[index]),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ChannelTile extends StatefulWidget {
  final Channel channel;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onPlay;
  const _ChannelTile({
    required this.channel,
    required this.selected,
    required this.onSelect,
    required this.onPlay,
  });

  @override
  State<_ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<_ChannelTile> {
  bool focused = false;

  @override
  Widget build(BuildContext context) {
    final program = context.watch<EpgService>().now(widget.channel.epgId);
    final favorite = context.watch<LibraryState>().isFavorite(widget.channel.id);

    return FocusableActionDetector(
      onShowFocusHighlight: (value) {
        setState(() => focused = value);
        if (value) widget.onSelect();
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onPlay,
          onLongPress: () => _favToggle(context, widget.channel),
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: const Color(0xFF111A29),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: focused || widget.selected
                    ? const Color(0xFF168BFF)
                    : const Color(0xFF1D2A3D),
                width: focused || widget.selected ? 1.8 : 1,
              ),
              boxShadow: focused
                  ? [
                      BoxShadow(
                        color: const Color(0xFF168BFF).withAlpha(35),
                        blurRadius: 12,
                      ),
                    ]
                  : [],
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: const Color(0xFF081323),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: widget.channel.logo.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(9),
                          child: Image.network(
                            widget.channel.logo,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.low,
                            errorBuilder: (_, __, ___) => const Icon(
                              Icons.live_tv_rounded,
                              color: Color(0xFF62B2FF),
                            ),
                          ),
                        )
                      : const Icon(
                          Icons.live_tv_rounded,
                          color: Color(0xFF62B2FF),
                        ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        widget.channel.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        program?.title ?? widget.channel.group,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF8FB9E8),
                        ),
                      ),
                      const SizedBox(height: 5),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: LinearProgressIndicator(
                          minHeight: 3,
                          value: program?.progress ?? 0,
                          backgroundColor: const Color(0xFF243247),
                          valueColor: const AlwaysStoppedAnimation(
                            Color(0xFF168BFF),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  tooltip: favorite ? 'إزالة من المفضلة' : 'إضافة للمفضلة',
                  onPressed: () => _favToggle(context, widget.channel),
                  icon: Icon(
                    favorite ? Icons.star_rounded : Icons.star_border_rounded,
                    size: 19,
                    color: favorite
                        ? const Color(0xFFFFB52E)
                        : const Color(0xFF64758C),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryDashboard extends StatelessWidget {
  final String title;
  final List<Channel> items;
  final List<String> categories;
  final String selectedCategory;
  final ValueChanged<String> onCategory;
  final ValueChanged<Channel> onPlay;
  const _LibraryDashboard({
    required this.title,
    required this.items,
    required this.categories,
    required this.selectedCategory,
    required this.onCategory,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
            child: _SectionTitle(title, subtitle: '${items.length} عنصر'),
          ),
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final c in categories)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(c),
                      selected: selectedCategory == c,
                      onSelected: (_) => onCategory(c),
                      selectedColor: const Color(0xFF15529A),
                      backgroundColor: const Color(0xFF111A29),
                      labelStyle: TextStyle(
                        color: selectedCategory == c ? Colors.white : const Color(0xFFB5C0D0),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text(
                      'لا توجد عناصر في هذا التصنيف',
                      style: TextStyle(color: Color(0xFF9BA9BD)),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      final columns = width >= 1200
                          ? 7
                          : width >= 900
                              ? 5
                              : width >= 650
                                  ? 4
                                  : width >= 420
                                      ? 3
                                      : 2;
                      return GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 22),
                        itemCount: items.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: 14,
                          mainAxisSpacing: 16,
                          childAspectRatio: 0.68,
                        ),
                        itemBuilder: (context, i) => _PosterTile(
                          channel: items[i],
                          onTap: () => onPlay(items[i]),
                        ),
                      );
                    },
                  ),
          ),
        ],
      );
}

class _PosterTile extends StatefulWidget {
  final Channel channel;
  final VoidCallback onTap;
  const _PosterTile({required this.channel, required this.onTap});

  @override
  State<_PosterTile> createState() => _PosterTileState();
}

class _PosterTileState extends State<_PosterTile> {
  bool focused = false;

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
        onShowFocusHighlight: (v) => setState(() => focused = v),
        child: GestureDetector(
          onTap: widget.onTap,
          onLongPress: () => _favToggle(context, widget.channel),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 150,
            decoration: BoxDecoration(
              color: const Color(0xFF101827),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: focused ? const Color(0xFFFF9200) : const Color(0xFF1D2A3D),
                width: focused ? 2.5 : 1,
              ),
              boxShadow: focused
                  ? [
                      BoxShadow(
                        color: const Color(0xFFFF9200).withAlpha(46),
                        blurRadius: 14,
                      ),
                    ]
                  : [],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      widget.channel.logo.isEmpty
                          ? const ColoredBox(
                              color: Color(0xFF0A1422),
                              child: Icon(Icons.movie_rounded, size: 48, color: Color(0xFF62B2FF)),
                            )
                          : Image.network(
                              widget.channel.logo,
                              fit: BoxFit.cover,
                              filterQuality: FilterQuality.low,
                              errorBuilder: (_, __, ___) => const ColoredBox(
                                color: Color(0xFF0A1422),
                                child: Icon(Icons.movie_rounded, size: 48),
                              ),
                            ),
                      Align(
                        alignment: Alignment.topRight,
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          iconSize: 18,
                          onPressed: () => _favToggle(context, widget.channel),
                          icon: Icon(
                            context.watch<LibraryState>().isFavorite(widget.channel.id)
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                            color: context.watch<LibraryState>().isFavorite(widget.channel.id)
                                ? const Color(0xFFFFB52E)
                                : Colors.white,
                          ),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black54,
                            padding: const EdgeInsets.all(5),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                  child: Text(
                    widget.channel.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  const _SectionTitle(this.title, {this.subtitle});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width: 4,
            height: 22,
            decoration: BoxDecoration(
              color: const Color(0xFF168BFF),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 10),
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          if (subtitle != null) ...[
            const SizedBox(width: 10),
            Text(
              subtitle!,
              style: const TextStyle(color: Color(0xFF7F90A8), fontSize: 11),
            ),
          ],
        ],
      );
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String title, detail;
  final VoidCallback action;
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
    required this.action,
  });

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 64, color: const Color(0xFF42A5FF)),
              const SizedBox(height: 18),
              Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF9BA9BD)),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: action,
                icon: const Icon(Icons.add_link),
                label: const Text('إعداد رابط القنوات'),
              ),
            ],
          ),
        ),
      );
}

class _SkeletonGrid extends StatefulWidget {
  const _SkeletonGrid();

  @override
  State<_SkeletonGrid> createState() => _SkeletonGridState();
}

class _SkeletonGridState extends State<_SkeletonGrid> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GridView.builder(
        padding: const EdgeInsets.all(14),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 230,
          mainAxisExtent: 70,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: 24,
        itemBuilder: (_, __) => FadeTransition(
          opacity: Tween<double>(begin: 0.3, end: 0.8).animate(_c),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF111A29),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      );
}
