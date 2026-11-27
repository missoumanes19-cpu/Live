import 'package:flutter_test/flutter_test.dart';
import 'package:anes_tv/services/playback_tuning.dart';

void main() {
  group('PlaybackTuning.boosted', () {
    test('المستوى 0 يطابق الخطة الأساسية', () {
      final b = PlaybackTuning.base(live: true, prebufferSec: 6);
      final p = PlaybackTuning.boosted(live: true, prebufferSec: 6, level: 0);
      expect(p.waitSec, b.waitSec);
      expect(p.aheadSec, b.aheadSec);
      expect(b.waitSec, 4); // البث المباشر لا ينتظر أكثر من 4 ثوانٍ مبدئياً
      expect(b.aheadSec, 30);
    });

    test('التعزيز يزيد الانتظار والقراءة المسبقة مع سقف آمن', () {
      final p = PlaybackTuning.boosted(live: true, prebufferSec: 6, level: 3);
      expect(p.waitSec, 10);
      expect(p.aheadSec, 75);
      final over = PlaybackTuning.boosted(live: true, prebufferSec: 30, level: 99);
      expect(over.waitSec, lessThanOrEqualTo(10));
      expect(over.aheadSec, lessThanOrEqualTo(75));
    });

    test('التخزين المعطّل (0) يبقى بانتظار 1 ثانية', () {
      expect(PlaybackTuning.base(live: true, prebufferSec: 0).waitSec, 1);
    });
  });

  group('levelForStalls / decay', () {
    final now = DateTime(2026, 11, 27, 12);
    test('تقطّعة واحدة لا ترفع المستوى', () {
      expect(PlaybackTuning.levelForStalls([now], now), 0);
    });
    test('تقطّعات متكررة ترفع المستوى تدريجياً', () {
      List<DateTime> n(int k) => List.generate(k, (i) => now.subtract(Duration(seconds: i * 5)));
      expect(PlaybackTuning.levelForStalls(n(2), now), 1);
      expect(PlaybackTuning.levelForStalls(n(4), now), 2);
      expect(PlaybackTuning.levelForStalls(n(6), now), 3);
    });
    test('التقطّعات القديمة خارج النافذة لا تُحتسب', () {
      final old = List.generate(8, (i) => now.subtract(const Duration(minutes: 10)));
      expect(PlaybackTuning.levelForStalls(old, now), 0);
    });
    test('الاستقرار الطويل يخفّض المستوى درجة واحدة فقط', () {
      expect(PlaybackTuning.decay(3, now.subtract(const Duration(minutes: 5)), now), 2);
      expect(PlaybackTuning.decay(3, now.subtract(const Duration(minutes: 1)), now), 3);
      expect(PlaybackTuning.decay(0, null, now), 0);
    });
  });

  group('اختيار المسارات', () {
    test('أفضل مسار لا يتجاوز 1080', () {
      expect(PlaybackTuning.bestTrackIndexUnder([2160, 1080, 720, null], 1080), 1);
      expect(PlaybackTuning.bestTrackIndexUnder([2160, 1440], 1080), isNull);
    });
    test('الخطوة للأسفل تختار أقرب معدل بت أقل', () {
      expect(PlaybackTuning.stepDownIndex([8000000, 4000000, 2000000], 0), 1);
      expect(PlaybackTuning.stepDownIndex([8000000, 4000000, 2000000], 2), isNull);
      expect(PlaybackTuning.stepDownIndex([null, null], 0), isNull);
    });
  });

  test('constrained: الأجهزة الضعيفة فقط، لا أجهزة التلفاز رباعية النواة', () {
    expect(PlaybackTuning.constrained(lite: true, cores: 8), isTrue);
    expect(PlaybackTuning.constrained(lite: false, cores: 2), isTrue);
    expect(PlaybackTuning.constrained(lite: false, cores: 4), isFalse);
  });
}
