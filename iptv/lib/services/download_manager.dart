import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'errors.dart';
import 'iptv_service.dart';

/// عنصر تنزيل (فيلم أو حلقة) محفوظ على الجهاز للمشاهدة بدون إنترنت
class DownloadItem {
  final String id;
  final Channel channel;
  final String path;
  int received, total;
  String status; // queued | downloading | paused | done | error
  String? error;
  final List<String> subtitles;
  final int created;

  DownloadItem({required this.id, required this.channel, required this.path, this.received = 0,
    this.total = 0, this.status = 'queued', this.error, List<String>? subtitles, int? created})
      : subtitles = subtitles ?? <String>[],
        created = created ?? DateTime.now().millisecondsSinceEpoch;

  double get progress => total > 0 ? (received / total).clamp(0.0, 1.0).toDouble() : 0.0;

  Map<String, dynamic> toMap() => {
    'id': id, 'channel': channel.toMap(), 'path': path, 'received': received, 'total': total,
    'status': status, 'error': error, 'subtitles': subtitles, 'created': created,
  };

  factory DownloadItem.fromMap(Map m) => DownloadItem(
    id: '${m['id']}', channel: Channel.fromMap(Map.from(m['channel'] as Map)), path: '${m['path']}',
    received: (m['received'] ?? 0) as int, total: (m['total'] ?? 0) as int,
    status: '${m['status'] ?? 'paused'}', error: m['error'] as String?,
    subtitles: List<String>.from((m['subtitles'] ?? const []) as List),
    created: m['created'] as int?);
}

class DownloadManager extends ChangeNotifier {
  static const maxParallel = 2;
  Box get _b => Hive.box('downloads');
  final Map<String, DownloadItem> _items = {};
  final Map<String, http.Client> _clients = {};
  Directory? _dir;

  List<DownloadItem> get list => _items.values.toList()
    ..sort((a, b) => b.created.compareTo(a.created));
  DownloadItem? byId(String id) => _items[id];

  static String idFor(String url) => md5.convert(utf8.encode(url)).toString().substring(0, 16);
  bool hasUrl(String url) => _items.containsKey(idFor(url));

  Future<void> init() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      _dir = Directory('${base.path}/downloads');
      await _dir!.create(recursive: true);
      for (final k in _b.keys) {
        final m = _b.get(k);
        if (m is! Map) continue;
        final it = DownloadItem.fromMap(Map.from(m));
        // أي تنزيل كان جارياً عند إغلاق التطبيق يصبح متوقفاً مؤقتاً
        if (it.status == 'downloading' || it.status == 'queued') it.status = 'paused';
        if (it.status == 'done' && !await File(it.path).exists()) continue;
        _items[it.id] = it;
      }
      notifyListeners();
    } catch (_) {}
  }

  void _save(DownloadItem it) { try { _b.put(it.id, it.toMap()); } catch (_) {} }

  /// يبدأ تنزيل فيلم/حلقة. يرجع false إن كان الرابط غير قابل للتنزيل
  Future<bool> enqueue(Channel c) async {
    final dir = _dir;
    if (dir == null) return false;
    final lower = c.url.toLowerCase();
    if (lower.contains('.m3u8') || lower.startsWith('file:') || !lower.startsWith('http')) return false;
    final id = idFor(c.url);
    final existing = _items[id];
    if (existing != null) {
      if (existing.status != 'done' && existing.status != 'downloading') resume(id);
      return true;
    }
    final ext = RegExp(r'\.(mp4|mkv|avi|mov|ts|webm|m4v|flv)(?:\?|$)').firstMatch(lower)?.group(1) ?? 'mp4';
    final it = DownloadItem(id: id, channel: c, path: '${dir.path}/$id.$ext');
    _items[id] = it;
    _save(it);
    notifyListeners();
    _pump();
    return true;
  }

  void _pump() {
    var running = _items.values.where((i) => i.status == 'downloading').length;
    for (final it in _items.values.toList()) {
      if (running >= maxParallel) break;
      if (it.status == 'queued') { running++; _run(it); }
    }
  }

  Future<void> _run(DownloadItem it) async {
    if (_clients.containsKey(it.id)) return;
    final client = http.Client();
    _clients[it.id] = client;
    it.status = 'downloading';
    it.error = null;
    _save(it);
    notifyListeners();
    IOSink? sink;
    try {
      final file = File(it.path);
      var start = await file.exists() ? await file.length() : 0;
      final req = http.Request('GET', Uri.parse(it.channel.url));
      req.headers.addAll(kHttpHeaders);
      if (start > 0) req.headers['Range'] = 'bytes=$start-';
      final resp = await client.send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) {
        start = 0; // السيرفر تجاهل Range: أعد التنزيل من البداية
      } else if (resp.statusCode != 206) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      sink = file.openWrite(mode: start > 0 ? FileMode.append : FileMode.write);
      final len = resp.contentLength ?? -1;
      if (len > 0) it.total = start + len;
      it.received = start;
      var last = DateTime.now();
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        it.received += chunk.length;
        if (DateTime.now().difference(last).inMilliseconds > 500) {
          last = DateTime.now();
          notifyListeners();
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (it.total <= 0) it.total = it.received;
      it.status = 'done';
    } catch (e) {
      try { await sink?.close(); } catch (_) {}
      // إن أوقفه المستخدم يبقى paused، وإلا فهو خطأ حقيقي
      if (it.status == 'downloading') { it.status = 'error'; it.error = friendlyError(e); }
    } finally {
      _clients.remove(it.id)?.close();
      _save(it);
      notifyListeners();
      _pump();
    }
  }

  void pause(String id) {
    final it = _items[id];
    if (it == null) return;
    if (it.status == 'downloading' || it.status == 'queued') {
      it.status = 'paused';
      _clients[id]?.close();
      _save(it);
      notifyListeners();
    }
  }

  void resume(String id) {
    final it = _items[id];
    if (it == null || it.status == 'done' || it.status == 'downloading') return;
    it.status = 'queued';
    it.error = null;
    _save(it);
    notifyListeners();
    _pump();
  }

  Future<void> delete(String id) async {
    final it = _items.remove(id);
    if (it == null) return;
    it.status = 'paused';
    _clients[id]?.close();
    try { await _b.delete(id); } catch (_) {}
    for (final p in [it.path, ...it.subtitles]) {
      try { final f = File(p); if (await f.exists()) await f.delete(); } catch (_) {}
    }
    notifyListeners();
  }

  /// ينسخ ملف الترجمة إلى مجلد التطبيق ويربطه بالتنزيل
  Future<String> addSubtitle(String id, String sourcePath) async {
    final it = _items[id];
    final dir = _dir;
    if (it == null || dir == null) return sourcePath;
    final subDir = Directory('${dir.path}/subs');
    await subDir.create(recursive: true);
    final name = sourcePath.split(RegExp(r'[\\/]')).last;
    final dest = '${subDir.path}/${id}_$name';
    await File(sourcePath).copy(dest);
    if (!it.subtitles.contains(dest)) it.subtitles.add(dest);
    _save(it);
    notifyListeners();
    return dest;
  }

  Future<void> removeSubtitle(String id, String path) async {
    final it = _items[id];
    if (it == null) return;
    it.subtitles.remove(path);
    try { final f = File(path); if (await f.exists()) await f.delete(); } catch (_) {}
    _save(it);
    notifyListeners();
  }
}
