import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:media_kit/media_kit.dart';
import '../services/radio_garden.dart';
import '../state/app_settings.dart';
import '../widgets/art.dart';

/// مشغّل صوتي واحد مشترك لكل شاشات الراديو (يستمر عند التنقل بينها)
class RadioPlayer extends ChangeNotifier {
  static final RadioPlayer instance = RadioPlayer._();
  RadioPlayer._();
  Player? _p;
  final List<StreamSubscription> _subs = [];
  RadioStation? current;
  bool playing = false, buffering = false;
  String? error;

  Player _create() {
    final p = Player();
    _subs
      ..add(p.stream.playing.listen((v) { playing = v; notifyListeners(); }))
      ..add(p.stream.buffering.listen((v) { buffering = v; notifyListeners(); }))
      ..add(p.stream.error.listen((e) {
        if (e.isNotEmpty) { error = t('تعذر تشغيل هذه المحطة'); buffering = false; notifyListeners(); }
      }));
    return p;
  }

  Future<void> play(RadioStation s) async {
    current = s;
    error = null;
    buffering = true;
    notifyListeners();
    try {
      _p ??= _create();
      await _p!.open(Media(s.streamUrl, httpHeaders: const {'User-Agent': 'Mozilla/5.0 (Linux; Android 13)'}), play: true);
    } catch (_) {
      error = t('تعذر تشغيل هذه المحطة');
      buffering = false;
      notifyListeners();
    }
  }

  void toggle() => _p?.playOrPause();

  Future<void> stop() async {
    if (current == null) return;
    current = null;
    playing = false;
    buffering = false;
    error = null;
    notifyListeners();
    try { await _p?.stop(); } catch (_) {}
  }
}

/// مفضلة الراديو (تُخزَّن في الإعدادات)
class RadioFavs {
  static const _k = 'radio_favs';
  static const _sep = '\u0001';
  static List<RadioStation> all() {
    final raw = Hive.box('settings').get(_k, defaultValue: <dynamic>[]) as List;
    return [
      for (final r in raw)
        if ('$r'.split(_sep).length >= 3) RadioStation('$r'.split(_sep)[0], '$r'.split(_sep)[1], '$r'.split(_sep)[2])
    ];
  }
  static bool has(String id) => all().any((s) => s.id == id);
  static void toggle(RadioStation s) {
    final list = all();
    if (list.any((e) => e.id == s.id)) {
      list.removeWhere((e) => e.id == s.id);
    } else {
      list.add(s);
    }
    Hive.box('settings').put(_k, [for (final e in list) '${e.id}$_sep${e.title}$_sep${e.subtitle}']);
  }
}

/// شريط التشغيل المصغّر أسفل شاشات الراديو
class RadioMiniBar extends StatelessWidget {
  const RadioMiniBar({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: RadioPlayer.instance,
    builder: (_, __) {
      final r = RadioPlayer.instance;
      final s = r.current;
      if (s == null) return const SizedBox.shrink();
      return Material(
        color: const Color(0xFF0D1726),
        child: SafeArea(top: false, child: ListTile(
          leading: Icon(Icons.radio_rounded, color: kAccent2, size: 30),
          title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(r.error ?? (r.buffering ? t('جارٍ التحميل…') : s.subtitle),
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: r.error != null ? Colors.redAccent : Colors.white60)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(icon: Icon(r.playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded, size: 34),
              onPressed: r.toggle),
            IconButton(icon: const Icon(Icons.stop_circle_outlined, size: 30), tooltip: t('إيقاف'), onPressed: r.stop),
          ]),
        )),
      );
    },
  );
}

class _Country {
  final String name;
  final String label;
  final int stations;
  final List<RadioPlace> places;
  _Country(this.name, this.label, this.stations, this.places);
}

/// الشاشة الرئيسية للراديو: بحث + المفضلة + الدول
class RadioScreen extends StatefulWidget {
  const RadioScreen({super.key});
  @override
  State<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends State<RadioScreen> {
  final _svc = RadioGardenService();
  final _q = TextEditingController();
  late Future<List<_Country>> _f = _load();

  Future<List<_Country>> _load({bool force = false}) async {
    final places = await _svc.places(force: force);
    final by = <String, List<RadioPlace>>{};
    for (final p in places) { (by[p.country] ??= []).add(p); }
    final list = [
      for (final e in by.entries)
        _Country(e.key, kArabCountries[e.key] ?? e.key, e.value.fold<int>(0, (a, p) => a + p.size),
          e.value..sort((a, b) => b.size.compareTo(a.size)))
    ];
    list.sort((a, b) {
      final aa = kArabCountries.containsKey(a.name), bb = kArabCountries.containsKey(b.name);
      if (aa != bb) return aa ? -1 : 1; // الدول العربية أولاً
      return a.label.compareTo(b.label);
    });
    return list;
  }

  void _search(String q) {
    q = q.trim();
    if (q.isEmpty) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => RadioStationsScreen.search(q)));
  }

  @override
  void dispose() { _q.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF05080F),
    appBar: AppBar(backgroundColor: const Color(0xFF080D17), title: Text(t('الراديو'))),
    bottomNavigationBar: const RadioMiniBar(),
    body: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 6), child: TextField(
        controller: _q, textInputAction: TextInputAction.search, onSubmitted: _search,
        decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: t('ابحث عن محطة راديو...'),
          filled: true, fillColor: Colors.white10, contentPadding: EdgeInsets.zero,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none)))),
      Expanded(child: FutureBuilder<List<_Country>>(future: _f, builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(), const SizedBox(height: 12), Text(t('جارٍ التحميل…'))]));
        }
        if (snap.hasError) {
          return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.wifi_off_rounded, size: 40, color: Colors.white54), const SizedBox(height: 8),
            Text(t('تعذر تحميل الراديو'), style: const TextStyle(color: Colors.white70)), const SizedBox(height: 10),
            FilledButton(onPressed: () => setState(() => _f = _load(force: true)), child: Text(t('إعادة المحاولة')))]));
        }
        final c = snap.data!;
        final favs = RadioFavs.all().length;
        return ListView.builder(itemCount: c.length + 2, itemBuilder: (_, i) {
          if (i == 0) {
            return ListTile(leading: Icon(Icons.star_rounded, color: kAccent2), title: Text(t('المفضلة')),
              trailing: Text('$favs', style: const TextStyle(color: Colors.white54)),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RadioStationsScreen.favs()))
                .then((_) => setState(() {})));
          }
          if (i == c.length + 1) {
            return const Padding(padding: EdgeInsets.all(14), child: Text('Radio Garden',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 11)));
          }
          final k = c[i - 1];
          return ListTile(leading: Icon(Icons.public_rounded, color: kAccent),
            title: Text(k.label), subtitle: Text('${k.stations} ${t('محطة')}', style: const TextStyle(fontSize: 12)),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RadioPlacesScreen(country: k))));
        });
      })),
    ]),
  );
}

/// مدن الدولة
class RadioPlacesScreen extends StatelessWidget {
  final _Country country;
  const RadioPlacesScreen({super.key, required this.country});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF05080F),
    appBar: AppBar(backgroundColor: const Color(0xFF080D17), title: Text(country.label)),
    bottomNavigationBar: const RadioMiniBar(),
    body: ListView.builder(itemCount: country.places.length, itemBuilder: (_, i) {
      final p = country.places[i];
      return ListTile(leading: Icon(Icons.location_city_rounded, color: kAccent),
        title: Text(p.title), trailing: Text('${p.size}', style: const TextStyle(color: Colors.white54)),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RadioStationsScreen.place(p))));
    }),
  );
}

enum _Mode { place, search, favs }

/// قائمة محطات: مدينة، أو نتائج بحث، أو المفضلة
class RadioStationsScreen extends StatefulWidget {
  final _Mode mode;
  final String title, arg;
  RadioStationsScreen.place(RadioPlace p, {super.key}) : mode = _Mode.place, title = p.title, arg = p.id;
  RadioStationsScreen.search(String q, {super.key}) : mode = _Mode.search, title = q, arg = q;
  RadioStationsScreen.favs({super.key}) : mode = _Mode.favs, title = t('المفضلة'), arg = '';
  @override
  State<RadioStationsScreen> createState() => _RadioStationsScreenState();
}

class _RadioStationsScreenState extends State<RadioStationsScreen> {
  final _svc = RadioGardenService();
  late Future<List<RadioStation>> _f = _load();

  Future<List<RadioStation>> _load() async {
    switch (widget.mode) {
      case _Mode.place: return _svc.channels(widget.arg);
      case _Mode.search: return _svc.search(widget.arg);
      case _Mode.favs: return RadioFavs.all();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF05080F),
    appBar: AppBar(backgroundColor: const Color(0xFF080D17), title: Text(widget.title)),
    bottomNavigationBar: const RadioMiniBar(),
    body: FutureBuilder<List<RadioStation>>(future: _f, builder: (ctx, snap) {
      if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
      if (snap.hasError) {
        return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t('تعذر تحميل الراديو'), style: const TextStyle(color: Colors.white70)), const SizedBox(height: 10),
          FilledButton(onPressed: () => setState(() => _f = _load()), child: Text(t('إعادة المحاولة')))]));
      }
      final list = snap.data!;
      if (list.isEmpty) return Center(child: Text(t('لا توجد نتائج'), style: const TextStyle(color: Colors.white54)));
      return ListenableBuilder(listenable: RadioPlayer.instance, builder: (_, __) => ListView.builder(
        itemCount: list.length, itemBuilder: (_, i) {
          final s = list[i];
          final on = RadioPlayer.instance.current?.id == s.id;
          final fav = RadioFavs.has(s.id);
          return ListTile(
            selected: on, selectedColor: kAccent2,
            leading: Icon(on && RadioPlayer.instance.playing ? Icons.graphic_eq_rounded : Icons.radio_rounded, color: on ? kAccent2 : kAccent),
            title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: s.subtitle.isEmpty ? null : Text(s.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            trailing: IconButton(icon: Icon(fav ? Icons.star_rounded : Icons.star_border_rounded, color: fav ? kAccent2 : Colors.white54),
              onPressed: () {
                RadioFavs.toggle(s);
                if (widget.mode == _Mode.favs) { setState(() => _f = _load()); } else { setState(() {}); }
              }),
            onTap: () => RadioPlayer.instance.play(s),
          );
        }));
    }),
  );
}
