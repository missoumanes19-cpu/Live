import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/iptv_service.dart';

/// يجعل زر "Select" في الريموت يعمل كضغطة
class TvApp extends StatelessWidget {
  final Widget child;
  const TvApp({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Shortcuts(
        shortcuts: {
          LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
          LogicalKeySet(LogicalKeyboardKey.gameButtonA): const ActivateIntent(),
          LogicalKeySet(LogicalKeyboardKey.numpadEnter): const ActivateIntent(),
        },
        child: child);
}

/// بطاقة كبيرة (10-foot UI) مع إبراز التركيز
class TvCard extends StatefulWidget {
  final Channel channel; final VoidCallback onSelect; final bool autofocus;
  const TvCard({super.key, required this.channel, required this.onSelect, this.autofocus = false});
  @override
  State<TvCard> createState() => _TvCardState();
}

class _TvCardState extends State<TvCard> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) => FocusableActionDetector(
        autofocus: widget.autofocus,
        onShowFocusHighlight: (v) {
          setState(() => _focused = v);
          if (v) Scrollable.ensureVisible(context, alignment: 0.5,
              duration: const Duration(milliseconds: 150));
        },
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) { widget.onSelect(); return null; })},
        child: GestureDetector(
          onTap: widget.onSelect,
          child: AnimatedScale(
            scale: _focused ? 1.1 : 1.0, duration: const Duration(milliseconds: 150),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.grey[900], borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _focused ? Colors.amber : Colors.transparent, width: 4)),
              child: Column(children: [
                Expanded(child: CachedNetworkImage(
                  imageUrl: widget.channel.logo, fit: BoxFit.contain,
                  memCacheWidth: 300, // تقليل استهلاك الذاكرة
                  errorWidget: (_, __, ___) => const Icon(Icons.tv, size: 48))),
                Padding(padding: const EdgeInsets.all(8),
                    child: Text(widget.channel.name, maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 22, color: Colors.white))),
              ]),
            ),
          ),
        ),
      );
}

/// شبكة كسولة + تحميل مجزّأ
class ChannelGrid extends StatefulWidget {
  final List<Channel> all; final void Function(Channel) onSelect;
  const ChannelGrid({super.key, required this.all, required this.onSelect});
  @override
  State<ChannelGrid> createState() => _ChannelGridState();
}

class _ChannelGridState extends State<ChannelGrid> {
  static const _page = 60;
  int _shown = _page;
  final _sc = ScrollController();
  @override
  void initState() {
    super.initState();
    _sc.addListener(() {
      if (_sc.position.pixels > _sc.position.maxScrollExtent - 600 && _shown < widget.all.length) {
        setState(() => _shown = (_shown + _page).clamp(0, widget.all.length));
      }
    });
  }
  @override
  void dispose() { _sc.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final n = _shown.clamp(0, widget.all.length);
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: GridView.builder(
        controller: _sc, padding: const EdgeInsets.all(24),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 280, mainAxisSpacing: 24, crossAxisSpacing: 24,
            childAspectRatio: 260 / 160),
        itemCount: n,
        itemBuilder: (_, i) => TvCard(channel: widget.all[i], autofocus: i == 0,
            onSelect: () => widget.onSelect(widget.all[i])),
      ),
    );
  }
}
