import 'package:flutter/material.dart';
import '../services/epg_service.dart';

String _hm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class EpgInfo extends StatelessWidget {
  final EpgService epg; final String? epgId;
  const EpgInfo({super.key, required this.epg, required this.epgId});
  @override
  Widget build(BuildContext context) {
    if (epgId == null) return const SizedBox.shrink();
    final n = epg.now(epgId!), x = epg.next(epgId!);
    if (n == null) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${_hm(n.start)}–${_hm(n.stop)}  ${n.title}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      LinearProgressIndicator(value: n.progress, minHeight: 2),
      if (x != null) Text('التالي ${_hm(x.start)}  ${x.title}',
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}
