import 'dart:convert';
import 'dart:typed_data';

class Cue {
  final Duration start, end;
  String text;
  Cue(this.start, this.end, this.text);
}

/// يفك ترميز ملف الترجمة (UTF-8 ثم Latin-1 كبديل)
String decodeSubtitle(Uint8List bytes) {
  try {
    return utf8.decode(bytes).replaceFirst('\uFEFF', '');
  } catch (_) {
    return latin1.decode(bytes);
  }
}

Duration? _time(String s) {
  final m = RegExp(r'(?:(\d+):)?(\d+):(\d+)[,.](\d+)').firstMatch(s.trim());
  if (m == null) return null;
  final ms = m[4]!.padRight(3, '0').substring(0, 3);
  return Duration(hours: int.parse(m[1] ?? '0'), minutes: int.parse(m[2]!),
      seconds: int.parse(m[3]!), milliseconds: int.parse(ms));
}

/// يقرأ srt / vtt / ass(ssa) ويرجع قائمة أسطر مؤقّتة
List<Cue> parseSubtitle(String content, String ext) {
  final text = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final cues = <Cue>[];
  if (ext == 'ass' || ext == 'ssa') {
    for (final line in text.split('\n')) {
      if (!line.startsWith('Dialogue:')) continue;
      final f = line.substring(9).split(',');
      if (f.length < 10) continue;
      final a = _time(f[1]), b = _time(f[2]);
      if (a == null || b == null) continue;
      final body = f.sublist(9).join(',').replaceAll(RegExp(r'\{[^}]*\}'), '')
          .replaceAll(r'\N', '\n').replaceAll(r'\n', '\n').trim();
      if (body.isNotEmpty) cues.add(Cue(a, b, body));
    }
    return cues;
  }
  for (final block in text.split(RegExp(r'\n{2,}'))) {
    final lines = block.split('\n');
    final i = lines.indexWhere((l) => l.contains('-->'));
    if (i < 0) continue;
    final parts = lines[i].split('-->');
    if (parts.length < 2) continue;
    final a = _time(parts[0]);
    final b = _time(parts[1].trim().split(RegExp(r'\s+')).first);
    if (a == null || b == null) continue;
    final body = lines.sublist(i + 1).join('\n').trim();
    if (body.isNotEmpty) cues.add(Cue(a, b, body));
  }
  return cues;
}

String _fmt(Duration d) {
  String p(int n, [int w = 2]) => n.toString().padLeft(w, '0');
  return '${p(d.inHours)}:${p(d.inMinutes % 60)}:${p(d.inSeconds % 60)},${p(d.inMilliseconds % 1000, 3)}';
}

String toSrt(List<Cue> cues) {
  final sb = StringBuffer();
  var i = 1;
  for (final c in cues) {
    if (c.text.trim().isEmpty) continue;
    sb.writeln(i++);
    sb.writeln('${_fmt(c.start)} --> ${_fmt(c.end)}');
    sb.writeln(c.text);
    sb.writeln();
  }
  return sb.toString();
}
