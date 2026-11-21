import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

class Program {
  final String title;
  final DateTime start, stop;
  Program(this.title, this.start, this.stop);
  bool get isNow { final n = DateTime.now(); return n.isAfter(start) && n.isBefore(stop); }
  double get progress {
    final total = stop.difference(start).inSeconds;
    if (total <= 0) return 0;
    return (DateTime.now().difference(start).inSeconds / total).clamp(0.0, 1.0).toDouble();
  }
}

// صيغة XMLTV: 20261116183000 +0100
DateTime _parseXmltvTime(String s) {
  final d = s.trim();
  final base = DateTime.utc(int.parse(d.substring(0, 4)), int.parse(d.substring(4, 6)),
      int.parse(d.substring(6, 8)), int.parse(d.substring(8, 10)),
      int.parse(d.substring(10, 12)), int.parse(d.substring(12, 14)));
  final m = RegExp(r'([+-])(\d\d)(\d\d)').firstMatch(d.substring(14));
  if (m == null) return base;
  final off = Duration(hours: int.parse(m[2]!), minutes: int.parse(m[3]!));
  return m[1] == '+' ? base.subtract(off) : base.add(off);
}

/// تعمل داخل isolate حتى لا تجمّد الواجهة: {channel: [[title, startMs, stopMs], ...]}
Map<String, List<List<Object>>> _parseXmltv(List<int> bytes) {
  final doc = XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));
  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final from = nowMs - 3 * 3600 * 1000;
  final to = nowMs + 24 * 3600 * 1000;
  final out = <String, List<List<Object>>>{};
  for (final p in doc.findAllElements('programme')) {
    try {
      final ch = p.getAttribute('channel');
      final st = p.getAttribute('start');
      final sp = p.getAttribute('stop');
      if (ch == null || st == null || sp == null) continue;
      final start = _parseXmltvTime(st).millisecondsSinceEpoch;
      final stop = _parseXmltvTime(sp).millisecondsSinceEpoch;
      if (stop < from || start > to) continue;
      final title = p.getElement('title')?.innerText ?? '';
      out.putIfAbsent(ch, () => <List<Object>>[]).add(<Object>[title, start, stop]);
    } catch (_) {}
  }
  return out;
}

class EpgService extends ChangeNotifier {
  Map<String, List<Program>> _by = {};
  bool loading = false;
  String? error;
  int count = 0;

  Future<void> load(String url) async {
    loading = true; error = null; notifyListeners();
    try {
      final client = http.Client();
      List<int> bytes;
      try {
        final resp = await client.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(seconds: 60));
        if (resp.statusCode != 200) throw Exception('EPG HTTP ${resp.statusCode}');
        final len = resp.contentLength;
        if (len != null && len > 40 * 1024 * 1024) throw Exception('EPG file too large');
        bytes = await resp.stream.toBytes().timeout(const Duration(seconds: 120));
      } finally {
        client.close();
      }
      final raw = await compute(_parseXmltv, bytes);
      final map = <String, List<Program>>{};
      raw.forEach((ch, list) {
        final l = list.map((e) => Program(e[0] as String,
            DateTime.fromMillisecondsSinceEpoch(e[1] as int),
            DateTime.fromMillisecondsSinceEpoch(e[2] as int))).toList()
          ..sort((a, b) => a.start.compareTo(b.start));
        map[ch] = l;
      });
      _by = map;
      count = map.length;
    } catch (e) {
      error = '$e';
    }
    loading = false;
    notifyListeners();
  }

  Program? now(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final p in _by[id] ?? const <Program>[]) { if (p.isNow) return p; }
    return null;
  }

  Program? next(String? id) {
    if (id == null || id.isEmpty) return null;
    final n = DateTime.now();
    for (final p in _by[id] ?? const <Program>[]) { if (p.start.isAfter(n)) return p; }
    return null;
  }
}
