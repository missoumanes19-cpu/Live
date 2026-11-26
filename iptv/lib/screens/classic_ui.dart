import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';
import '../config.dart';
import '../services/epg_service.dart';
import '../services/iptv_service.dart';
import '../state/app_settings.dart';
import '../state/library_state.dart';
import '../widgets/load_progress.dart';
import 'diagnostics_screen.dart';
import 'downloads_screen.dart';
import '../services/download_manager.dart';

const _gold = Color(0xFFFFD84D);
const _panel = Color(0x33FFFFFF);

/// واجهة بنمط IBO Player: قائمة رئيسية ثم شاشة ثلاثية الأعمدة (تصنيفات | قنوات | معاينة)
class ClassicHome extends StatelessWidget {
  final String section;
  final List<Channel> items;
  final List<String> categories;
  final Map<String, int> counts;
  final String category;
  final Channel? selected;
  final bool loading, hasData;
  final double? progress;
  final int bytes;
  final String loadingLabel;
  final String? error;
  final TextEditingController search;
  final ValueChanged<String> onQuery, onSection, onCategory;
  final ValueChanged<Channel> onSelect, onPlay;
  final VoidCallback onServer, onReload, onSettings, onExit;
  const ClassicHome({super.key, required this.section, required this.items, required this.categories,
    required this.counts, required this.category, required this.selected, required this.loading,
    this.progress, this.bytes = 0, this.loadingLabel = '',
    required this.hasData, required this.error, required this.search, required this.onQuery,
    required this.onSection, required this.onCategory, required this.onSelect, required this.onPlay,
    required this.onServer, required this.onReload, required this.onSettings, required this.onExit});

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
      colors: [Color(0xFF0B1030), Color(0xFF1B0F44), Color(0xFF2B0B55)])),
    child: SafeArea(child: section == 'الرئيسية'
      ? _Menu(onSection: onSection, onServer: onServer, onReload: onReload, onSettings: onSettings,
          onExit: onExit, onPlay: onPlay)
      : _Browser(this)),
  );
}

// ======================= القائمة الرئيسية =======================
class _Menu extends StatelessWidget {
  final ValueChanged<String> onSection; final ValueChanged<Channel> onPlay;
  final VoidCallback onServer, onReload, onSettings, onExit;
  const _Menu({required this.onSection, required this.onPlay, required this.onServer, required this.onReload,
    required this.onSettings, required this.onExit});

  @override
  Widget build(BuildContext context) {
    final box = Hive.box('settings');
    final name = box.get('last_server_name') as String?;
    final last = box.get('last_channel');
    Widget tile(IconData i, String label, VoidCallback f, {bool big = false, bool flat = false}) =>
        _Tile(icon: i, label: label, onTap: f, big: big, flat: flat);
    final account = () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DiagnosticsScreen()));
    final header = Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: Row(children: [
        if (last is Map) ActionChip(
          avatar: const Icon(Icons.history, size: 16), label: Text('${t('آخر قناة')}: ${last['name']}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
          onPressed: () => onPlay(Channel.fromMap(Map.from(last)))),
        const SizedBox(width: 8),
        ActionChip(avatar: const Icon(Icons.download_rounded, size: 16), label: Text(t('التنزيلات')),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DownloadsScreen()))),
        const Spacer(),
        if (name != null) Text(name, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ])),
      Image.asset('assets/logo.png', height: 84),
    ]);
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= 640;
      final tiles = <Widget>[
        tile(Icons.live_tv_rounded, t('البث المباشر'), () => onSection('البث المباشر'), big: true),
        tile(Icons.movie_rounded, t('الأفلام'), () => onSection('الأفلام')),
        tile(Icons.video_library_rounded, t('المسلسلات'), () => onSection('المسلسلات')),
        tile(Icons.person_rounded, t('حساب'), account),
        tile(Icons.swap_horiz_rounded, t('تغيير القائمة'), onServer),
        tile(Icons.settings_rounded, t('الإعدادات'), onSettings, flat: true),
        tile(Icons.refresh_rounded, t('إعادة تحميل'), onReload, flat: true),
        tile(Icons.logout_rounded, t('خروج'), onExit, flat: true),
      ];
      if (!wide) {
        return Column(children: [
          header,
          Expanded(child: GridView.count(crossAxisCount: 2, padding: const EdgeInsets.all(14),
            mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1.5, children: tiles)),
          Padding(padding: const EdgeInsets.only(right: 16, bottom: 6), child: Align(
            alignment: Alignment.centerRight, child: Text('v${AppConfig.version}', style: const TextStyle(color: Colors.white54)))),
        ]);
      }
      return Column(children: [
        header,
        Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(28, 10, 28, 6), child: Row(children: [
          Expanded(flex: 5, child: tiles[0]),
          const SizedBox(width: 12),
          Expanded(flex: 5, child: Column(children: [
            Expanded(child: Row(children: [Expanded(child: tiles[1]), const SizedBox(width: 12), Expanded(child: tiles[2])])),
            const SizedBox(height: 12),
            Expanded(child: Row(children: [Expanded(child: tiles[3]), const SizedBox(width: 12), Expanded(child: tiles[4])])),
          ])),
          const SizedBox(width: 12),
          Expanded(flex: 4, child: Column(children: [
            Expanded(child: tiles[5]), const SizedBox(height: 12),
            Expanded(child: tiles[6]), const SizedBox(height: 12),
            Expanded(child: tiles[7]),
          ])),
        ]))),
        Padding(padding: const EdgeInsets.only(right: 28, bottom: 8), child: Align(
          alignment: Alignment.centerRight, child: Text('v${AppConfig.version}', style: const TextStyle(color: Colors.white54)))),
      ]);
    });
  }
}

class _Tile extends StatefulWidget {
  final IconData icon; final String label; final VoidCallback onTap; final bool big, flat;
  const _Tile({required this.icon, required this.label, required this.onTap, this.big = false, this.flat = false});
  @override
  State<_Tile> createState() => _TileState();
}
class _TileState extends State<_Tile> {
  bool focused = false;
  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    onShowFocusHighlight: (v) => setState(() => focused = v),
    child: InkWell(onTap: widget.onTap, borderRadius: BorderRadius.circular(10), child: AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10),
        gradient: widget.flat ? null : const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [Color(0xFF6A2CD8), Color(0xFF2B1B8F)]),
        color: widget.flat ? const Color(0x33FFFFFF) : null,
        border: Border.all(color: focused ? _gold : Colors.white12, width: focused ? 2.5 : 1)),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: widget.flat
        ? [Icon(widget.icon, size: 26, color: Colors.white), const SizedBox(width: 10),
           Flexible(child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)))]
        : [Flexible(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(widget.icon, size: widget.big ? 76 : 38, color: Colors.white),
            SizedBox(height: widget.big ? 14 : 6),
            Text(widget.label, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: widget.big ? 22 : 14, fontWeight: FontWeight.w600)),
          ]))]))),
  );
}

// ======================= شاشة القنوات ثلاثية الأعمدة =======================
class _Browser extends StatelessWidget {
  final ClassicHome h;
  const _Browser(this.h);

  @override
  Widget build(BuildContext context) => Column(children: [
    _TopTabs(h),
    Container(height: 2, color: Colors.white24),
    Expanded(child: h.loading ? LoadProgress(label: h.loadingLabel, fraction: h.progress, bytes: h.bytes)
      : h.error != null ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(h.error!,
          textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent))))
      : !h.hasData ? Center(child: FilledButton.icon(onPressed: h.onServer, icon: const Icon(Icons.dns_rounded),
          label: Text(t('تغيير القائمة'))))
      : LayoutBuilder(builder: (context, c) => _Panes(h, wide: c.maxWidth >= 640))),
  ]);
}

class _TopTabs extends StatelessWidget {
  final ClassicHome h;
  const _TopTabs(this.h);
  @override
  Widget build(BuildContext context) {
    Widget tab(String label, String section) {
      final on = h.section == section;
      return InkWell(onTap: () => h.onSection(section), child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Text(label, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: on ? _gold : Colors.white))));
    }
    return Row(children: [
      Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
        tab(t('الرئيسية'), 'الرئيسية'), tab(t('البث المباشر'), 'البث المباشر'),
        tab(t('الأفلام'), 'الأفلام'), tab(t('المسلسلات'), 'المسلسلات'),
        InkWell(onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DownloadsScreen())),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [const Icon(Icons.download_rounded, size: 17), const SizedBox(width: 4),
              Text(t('التنزيلات'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))]))),
      ]))),
      SizedBox(width: 200, height: 38, child: TextField(controller: h.search, onChanged: h.onQuery,
        decoration: InputDecoration(prefixIcon: const Icon(Icons.search, size: 20), hintText: t('ابحث عن محتوى...'),
          contentPadding: EdgeInsets.zero, filled: true, fillColor: Colors.white10,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none)))),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Image.asset('assets/logo.png', height: 30)),
    ]);
  }
}

class _Panes extends StatelessWidget {
  final ClassicHome h; final bool wide;
  const _Panes(this.h, {required this.wide});

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryState>();
    final cats = <(String, String, int)>[
      ('__recent', t('مشاهدة حديثاً'), lib.history.length),
      ('الكل', t('الكل'), h.counts['الكل'] ?? 0),
      ('__fav', t('المفضلة'), lib.favorites.length),
      for (final c in h.categories.where((c) => c != 'الكل')) (c, c, h.counts[c] ?? 0),
    ];
    final cur = h.items.isEmpty ? null
        : (h.selected != null && h.items.any((e) => e.url == h.selected!.url) ? h.selected : h.items.first);
    final catPane = SizedBox(width: wide ? 180 : 110, child: ListView.builder(padding: const EdgeInsets.all(6),
      itemCount: cats.length, itemBuilder: (_, i) {
        final c = cats[i]; final on = c.$1 == h.category;
        return InkWell(onTap: () => h.onCategory(c.$1), child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: EdgeInsets.symmetric(horizontal: wide ? 12 : 8, vertical: 8),
          color: on ? const Color(0x55FFFFFF) : _panel,
          child: Row(children: [
            Expanded(child: Text(c.$2, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: wide ? 12.5 : 11, color: on ? _gold : Colors.white))),
            Text('${c.$3}', style: TextStyle(fontSize: wide ? 11 : 10, color: on ? _gold : Colors.white70)),
          ])));
      }));
    final list = ListView.builder(padding: const EdgeInsets.all(6), itemCount: h.items.length, itemBuilder: (_, i) {
      final ch = h.items[i]; final on = cur != null && ch.url == cur.url;
      return InkWell(
        onTap: () { if (!wide || on) { h.onPlay(ch); } else { h.onSelect(ch); } },
        onLongPress: () => lib.toggleFavorite(ch),
        child: Container(margin: const EdgeInsets.symmetric(vertical: 1), height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          color: on ? const Color(0x66FFFFFF) : _panel,
          child: Row(children: [
            SizedBox(width: 30, child: Text('${i + 1}', style: TextStyle(fontSize: 11, color: on ? _gold : Colors.white70))),
            Container(width: 28, height: 28, color: Colors.black26, child: ch.logo.isEmpty
              ? const Icon(Icons.tv, size: 16, color: Colors.white54)
              : CachedNetworkImage(imageUrl: ch.logo, fit: BoxFit.contain, memCacheWidth: 100,
                  errorWidget: (_, __, ___) => const Icon(Icons.tv, size: 16, color: Colors.white54))),
            const SizedBox(width: 8),
            Expanded(child: Text(ch.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: on ? _gold : Colors.white))),
            if (lib.isFavorite(ch.id)) const Icon(Icons.star, size: 13, color: _gold),
          ])));
    });
    final divider = Container(width: 2, color: Colors.white24);
    if (!wide) return Row(children: [catPane, divider, Expanded(child: list)]);
    return Row(children: [catPane, divider, Expanded(flex: 4, child: list), divider,
      Expanded(flex: 5, child: _Preview(h: h, ch: cur))]);
  }
}

class _Preview extends StatelessWidget {
  final ClassicHome h; final Channel? ch;
  const _Preview({required this.h, required this.ch});
  String _hm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  @override
  Widget build(BuildContext context) {
    final c = ch;
    if (c == null) return Center(child: Text(t('اختر قناة'), style: const TextStyle(color: Colors.white54)));
    final epg = context.watch<EpgService>();
    final lib = context.watch<LibraryState>();
    final now = epg.now(c.epgId), next = epg.next(c.epgId);
    final fav = lib.isFavorite(c.id);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AspectRatio(aspectRatio: 16 / 9, child: InkWell(onTap: () => h.onPlay(c), child: Container(color: Colors.black,
        child: Stack(alignment: Alignment.center, children: [
          if (c.logo.isNotEmpty) Padding(padding: const EdgeInsets.all(18), child: CachedNetworkImage(
            imageUrl: c.logo, fit: BoxFit.contain, memCacheWidth: 400, errorWidget: (_, __, ___) => const SizedBox())),
          const Icon(Icons.play_circle_fill_rounded, size: 56, color: Colors.white70),
        ])))),
      Expanded(child: Container(padding: const EdgeInsets.all(14), color: Colors.black26,
        child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          if (now != null) ...[
            Text('${_hm(now.start)} – ${_hm(now.stop)}   ${now.title}', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 6), LinearProgressIndicator(value: now.progress, minHeight: 3),
          ],
          if (next != null) Padding(padding: const EdgeInsets.only(top: 6),
            child: Text('${t('التالي')} ${_hm(next.start)}  ${next.title}', style: const TextStyle(color: Colors.white54, fontSize: 12))),
          const SizedBox(height: 14),
          Wrap(spacing: 10, runSpacing: 8, children: [
            FilledButton.icon(onPressed: () => h.onPlay(c), icon: const Icon(Icons.play_arrow), label: Text(t('تشغيل'))),
            if (h.section == 'الأفلام') OutlinedButton.icon(
              onPressed: () async {
                final ok = await context.read<DownloadManager>().enqueue(c);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(ok ? t('بدأ التحميل') : t('هذا الرابط لا يدعم التحميل'))));
                }
              },
              icon: const Icon(Icons.download_rounded), label: Text(t('تحميل'))),
            OutlinedButton.icon(onPressed: () => lib.toggleFavorite(c),
              icon: Icon(fav ? Icons.star : Icons.star_border), label: Text(fav ? t('إزالة من المفضلة') : t('أضف للمفضلة'))),
          ]),
        ])))),
    ]);
  }
}
