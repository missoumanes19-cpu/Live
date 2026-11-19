import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

class Program {
  final String channelId, title;
  final DateTime start, stop;
  Program(this.channelId, this.title, this.start, this.stop);
  bool get isNow { final n = DateTime.now(); return n.isAfter(start) && n.isBefore(stop); }
  double get progress => (DateTime.now().difference(start).inSeconds /
      stop.difference(start).inSeconds).clamp(0.0, 1.0);
}

class EpgService {
  final Map<String, List<Program>> _byChannel = {};

  // صيغة XMLTV: 20261116183000 +0100
  static DateTime _parse(String s) {
    final d = s.substring(0, 14);
    final base = DateTime.utc(int.parse(d.substring(0, 4)), int.parse(d.substring(4, 6)),
        int.parse(d.substring(6, 8)), int.parse(d.substring(8, 10)),
        int.parse(d.substring(10, 12)), int.parse(d.substring(12, 14)));
    final m = RegExp(r'([+-])(\d\d)(\d\d)').firstMatch(s.substring(14));
    if (m == null) return base.toLocal();
    final off = Duration(hours: int.parse(m[2]!), minutes: int.parse(m[3]!));
    return (m[1] == '+' ? base.subtract(off) : base.add(off)).toLocal();
  }

  Future<void> load(String url) async {
    final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 60));
    final doc = XmlDocument.parse(res.body); // للملفات الضخمة: نفّذها داخل compute()
    _byChannel.clear();
    for (final p in doc.findAllElements('programme')) {
      final ch = p.getAttribute('channel')!;
      _byChannel.putIfAbsent(ch, () => []).add(Program(
          ch, p.getElement('title')?.innerText ?? '',
          _parse(p.getAttribute('start')!), _parse(p.getAttribute('stop')!)));
    }
    for (final l in _byChannel.values) { l.sort((a, b) => a.start.compareTo(b.start)); }
  }

  Program? now(String id) {
    for (final p in _byChannel[id] ?? const <Program>[]) { if (p.isNow) return p; }
    return null;
  }

  Program? next(String id) {
    final n = DateTime.now();
    for (final p in _byChannel[id] ?? const <Program>[]) { if (p.start.isAfter(n)) return p; }
    return null;
  }
}
