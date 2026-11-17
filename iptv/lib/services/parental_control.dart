import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

class ParentalControl extends ChangeNotifier {
  final _box = Hive.box('settings');

  String _hash(String pin) => sha256.convert(utf8.encode('iptv_salt_$pin')).toString();
  bool get hasPin => _box.get('pin') != null;
  bool verify(String pin) => _box.get('pin') == _hash(pin);
  Set<String> get locked => Set<String>.from(_box.get('locked', defaultValue: <String>[]));
  bool isLocked(String category) => locked.contains(category);

  bool setPin(String pin, {String? oldPin}) {
    if (hasPin && (oldPin == null || !verify(oldPin))) return false;
    _box.put('pin', _hash(pin)); notifyListeners(); return true;
  }

  void toggleCategory(String category) {
    final s = locked; s.contains(category) ? s.remove(category) : s.add(category);
    _box.put('locked', s.toList()); notifyListeners();
  }

  /// استدعها قبل فتح أي تصنيف محجوب
  Future<bool> guard(BuildContext ctx, String category) async {
    if (!isLocked(category)) return true;
    final c = TextEditingController();
    final ok = await showDialog<bool>(context: ctx, builder: (d) => AlertDialog(
      title: const Text('أدخل رمز PIN'),
      content: TextField(controller: c, obscureText: true, autofocus: true,
          keyboardType: TextInputType.number, maxLength: 4),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('إلغاء')),
        TextButton(onPressed: () => Navigator.pop(d, verify(c.text)), child: const Text('موافق')),
      ],
    ));
    return ok ?? false;
  }
}
