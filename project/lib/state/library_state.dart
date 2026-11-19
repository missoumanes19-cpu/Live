import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import '../services/iptv_service.dart';

// Boxes: favorites, history, positions, settings  (Hive.openBox في main)
class LibraryState extends ChangeNotifier {
  final _fav = Hive.box('favorites');
  final _hist = Hive.box('history');
  final _pos = Hive.box('positions');

  List<Channel> get favorites => _fav.values.map((e) => Channel.fromMap(e)).toList();
  List<Channel> get history {
    final items = _hist.values.toList()..sort((a, b) => b['at'].compareTo(a['at']));
    return items.map((e) => Channel.fromMap(e['ch'])).toList();
  }

  bool isFavorite(String id) => _fav.containsKey(id);

  void toggleFavorite(Channel c) {
    isFavorite(c.id) ? _fav.delete(c.id) : _fav.put(c.id, c.toMap());
    notifyListeners();
  }

  void addHistory(Channel c) {
    _hist.put(c.id, {'ch': c.toMap(), 'at': DateTime.now().millisecondsSinceEpoch});
    if (_hist.length > 100) {
      final items = _hist.toMap().entries.toList()
        ..sort((a, b) => a.value['at'].compareTo(b.value['at']));
      _hist.delete(items.first.key); // حذف الأقدم
    }
    notifyListeners();
  }

  void savePosition(String id, Duration p) => _pos.put(id, p.inSeconds);
  Duration resumePosition(String id) => Duration(seconds: (_pos.get(id) ?? 0) as int);
}
