import 'dart:io' show Platform;

/// خطة التخزين المؤقت المحسوبة (ثوانٍ)
class BufferPlan {
  /// الانتظار قبل استئناف التشغيل بعد توقف التخزين (cache-pause-wait)
  final int waitSec;

  /// مقدار ما نقرؤه مسبقاً (cache-secs / demuxer-readahead-secs)
  final int aheadSec;
  const BufferPlan(this.waitSec, this.aheadSec);
}

/// منطق ضبط التشغيل بدون أي اعتماد على المشغّل نفسه، ليسهل اختباره.
class PlaybackTuning {
  /// أقصى مستوى تعزيز للتخزين المؤقت
  static const int maxLevel = 3;

  /// نافذة احتساب التقطّعات المتكررة
  static const Duration stallWindow = Duration(minutes: 3);

  /// مدة استقرار تُخفَّض بعدها مستوى التعزيز درجة واحدة
  static const Duration calmPeriod = Duration(minutes: 4);

  /// جهاز محدود القدرة: وضع الأجهزة الضعيفة أو معالج بأربع أنوية أو أقل.
  static bool constrained({required bool lite, int? cores}) {
    final c = cores ?? _cores();
    return lite || (c > 0 && c <= 2);
  }

  static int _cores() {
    try {
      return Platform.numberOfProcessors;
    } catch (_) {
      return 0;
    }
  }

  /// الخطة الأساسية (قبل أي تعزيز) كما كانت تُحسب في المشغّل.
  static BufferPlan base({required bool live, required int prebufferSec}) {
    final wait = prebufferSec <= 0 ? 1 : (live && prebufferSec > 4 ? 4 : prebufferSec);
    final ahead = live ? 30 : (prebufferSec * 3).clamp(30, 300).toInt();
    return BufferPlan(wait, ahead);
  }

  /// يزيد الخطة الأساسية حسب [level] (0 = بدون تعزيز) مع سقف آمن.
  static BufferPlan boosted({required bool live, required int prebufferSec, required int level}) {
    final b = base(live: live, prebufferSec: prebufferSec);
    final l = level.clamp(0, maxLevel).toInt();
    if (l == 0) return b;
    final wait = (b.waitSec + l * 2).clamp(1, live ? 10 : 20).toInt();
    final ahead = (b.aheadSec + l * 15).clamp(30, live ? 75 : 300).toInt();
    return BufferPlan(wait, ahead);
  }

  /// المستوى المقترح من عدد مرات التقطّع خلال [stallWindow].
  static int levelForStalls(List<DateTime> stalls, DateTime now) {
    final n = stalls.where((s) => now.difference(s) <= stallWindow).length;
    if (n >= 6) return 3;
    if (n >= 4) return 2;
    if (n >= 2) return 1;
    return 0;
  }

  /// يخفّض المستوى درجة بعد فترة هدوء طويلة بلا تقطّع.
  static int decay(int level, DateTime? lastStall, DateTime now) {
    if (level <= 0 || lastStall == null) return level;
    return now.difference(lastStall) >= calmPeriod ? level - 1 : level;
  }

  /// أفضل مسار فيديو لا يتجاوز [maxHeight]؛ null إن لم يوجد ما يناسب.
  /// [heights] ارتفاعات المسارات المتاحة (null عندما لا يُعرف الارتفاع).
  static int? bestTrackIndexUnder(List<int?> heights, int maxHeight) {
    int? best;
    int bestH = -1;
    for (var i = 0; i < heights.length; i++) {
      final h = heights[i];
      if (h == null || h <= 0 || h > maxHeight) continue;
      if (h > bestH) {
        bestH = h;
        best = i;
      }
    }
    return best;
  }

  /// أول مسار أدنى جودة من الحالي (بحسب معدل البت) أو null.
  static int? stepDownIndex(List<int?> bitrates, int currentIndex) {
    if (currentIndex < 0 || currentIndex >= bitrates.length) return null;
    final cur = bitrates[currentIndex];
    if (cur == null || cur <= 0) return null;
    int? best;
    int bestBr = -1;
    for (var i = 0; i < bitrates.length; i++) {
      final b = bitrates[i];
      if (b == null || b <= 0 || b >= cur) continue;
      if (b > bestBr) {
        bestBr = b;
        best = i;
      }
    }
    return best;
  }
}
