import 'package:flutter/material.dart';

/// دائرة تحميل مع نسبة مئوية (أو حجم البيانات المستلمة إن كان الحجم الكلي مجهولاً)
class LoadProgress extends StatelessWidget {
  final String label;
  final double? fraction; // 0..1 أو null
  final int bytes;
  const LoadProgress({super.key, required this.label, required this.fraction, this.bytes = 0});

  @override
  Widget build(BuildContext context) {
    final pct = fraction == null ? null : (fraction! * 100).clamp(0, 100).floor();
    final mb = bytes > 0 ? '${(bytes / 1048576).toStringAsFixed(1)} MB' : '';
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 92, height: 92,
          child: Stack(alignment: Alignment.center, children: [
            SizedBox(width: 92, height: 92,
                child: CircularProgressIndicator(value: fraction, strokeWidth: 6)),
            Text(pct == null ? '…' : '$pct%',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
          ]),
        ),
        const SizedBox(height: 14),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 15)),
        if (mb.isNotEmpty) Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(mb, style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ),
      ]),
    );
  }
}
