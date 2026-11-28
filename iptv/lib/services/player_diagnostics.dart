import 'dart:async';
import 'dart:io';
import '../state/app_settings.dart' show t;

/// أنواع فشل التشغيل التي نعرضها للمستخدم برسائل واضحة
enum PlayerFailure {
  timeout,
  invalidStream,
  networkUnavailable,
  unsupportedFormat,
  serverUnavailable,
  playbackFailure,
}

class PlayerDiagnosis {
  final PlayerFailure kind;
  final String raw; // النص الأصلي من المشغّل (للتشخيص فقط)
  final int? httpCode;
  const PlayerDiagnosis(this.kind, this.raw, {this.httpCode});

  /// الأخطاء التي لا فائدة من إعادة المحاولة معها (الرابط/الصيغة نفسها مشكلة)
  bool get retryable => kind != PlayerFailure.invalidStream && kind != PlayerFailure.unsupportedFormat;

  String get title => switch (kind) {
        PlayerFailure.timeout => t('انتهت مهلة الاتصال'),
        PlayerFailure.invalidStream => t('رابط البث غير صالح'),
        PlayerFailure.networkUnavailable => t('لا يوجد اتصال بالإنترنت'),
        PlayerFailure.unsupportedFormat => t('صيغة غير مدعومة'),
        PlayerFailure.serverUnavailable => t('السيرفر غير متاح'),
        PlayerFailure.playbackFailure => t('فشل التشغيل'),
      };

  String get message => switch (kind) {
        PlayerFailure.timeout => t('السيرفر لم يستجب في الوقت المحدد. تحقق من سرعة الإنترنت ثم أعد المحاولة.'),
        PlayerFailure.invalidStream => httpCode == 404 || httpCode == 410
            ? t('القناة أو الملف غير موجود على السيرفر (404).')
            : t('الرابط لا يشير إلى بث صالح. قد يكون منتهياً أو غير صحيح.'),
        PlayerFailure.networkUnavailable => t('تحقق من اتصال الواي فاي أو بيانات الهاتف. سيُستأنف البث تلقائياً عند عودة الشبكة.'),
        PlayerFailure.unsupportedFormat => t('هذا البث يستخدم صيغة أو ترميزاً لا يدعمه المشغّل. جرّب مشغّلاً داخلياً آخر من الإعدادات.'),
        PlayerFailure.serverUnavailable => httpCode == 401 || httpCode == 403
            ? '${t('رفض السيرفر الطلب')} ($httpCode). ${t('تحقق من بيانات الدخول أو انتهاء الاشتراك أو حد الاتصالات.')}'
            : t('تعذّر الوصول إلى سيرفر البث أو أنه متوقف مؤقتاً. حاول لاحقاً.'),
        PlayerFailure.playbackFailure => t('حدث خطأ أثناء التشغيل. جرّب إعادة التحميل أو تغيير وضع فك التشفير.'),
      };
}

/// تصنيف نص الخطأ القادم من mpv / FFmpeg (بدون اتصال بالشبكة)
PlayerDiagnosis classifyPlayerError(String raw) {
  final s = raw.toLowerCase();
  final code = int.tryParse(
      RegExp(r'(?:http error|server returned|http status|status code)\s*:?\s*(\d{3})').firstMatch(s)?.group(1) ?? '');

  if (code != null) {
    if (code == 408 || code == 504) return PlayerDiagnosis(PlayerFailure.timeout, raw, httpCode: code);
    if (code == 404 || code == 410 || code == 400) {
      return PlayerDiagnosis(PlayerFailure.invalidStream, raw, httpCode: code);
    }
    if (code == 401 || code == 403 || code == 429 || code == 451 || code >= 500) {
      return PlayerDiagnosis(PlayerFailure.serverUnavailable, raw, httpCode: code);
    }
  }
  bool has(List<String> keys) => keys.any(s.contains);

  if (has(['timed out', 'timeout', 'etimedout', 'stalled'])) {
    return PlayerDiagnosis(PlayerFailure.timeout, raw);
  }
  if (has(['network is unreachable', 'no route to host', 'failed to resolve', 'name or service not known',
      'could not resolve', 'no address associated', 'failed host lookup', 'socketexception'])) {
    return PlayerDiagnosis(PlayerFailure.networkUnavailable, raw);
  }
  if (has(['connection refused', 'connection reset', 'connection closed', 'broken pipe', 'end of file',
      'stream ended', 'server error'])) {
    return PlayerDiagnosis(PlayerFailure.serverUnavailable, raw);
  }
  if (has(['unsupported', 'codec not found', 'could not find codec', 'decoder not found', 'no decoder'])) {
    return PlayerDiagnosis(PlayerFailure.unsupportedFormat, raw);
  }
  if (has(['failed to recognize file format', 'unrecognized file format', 'invalid data found',
      'invalid url', 'protocol not found', 'no video or audio streams', 'moov atom not found'])) {
    return PlayerDiagnosis(PlayerFailure.invalidStream, raw);
  }
  return PlayerDiagnosis(PlayerFailure.playbackFailure, raw);
}

/// هل يوجد إنترنت فعلاً؟ (فحص DNS لعنوانين بالتوازي، بحد أقصى ثوانٍ قليلة)
Future<bool> hasInternet({Duration timeout = const Duration(seconds: 3)}) async {
  Future<bool> probe(String host) async {
    try {
      final r = await InternetAddress.lookup(host).timeout(timeout);
      return r.isNotEmpty && r.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  final res = await Future.wait([probe('google.com'), probe('cloudflare.com')]);
  return res.any((e) => e);
}

/// هل يقبل سيرفر البث اتصال TCP؟
Future<bool> serverReachable(String url, {Duration timeout = const Duration(seconds: 4)}) async {
  final u = Uri.tryParse(url);
  if (u == null || !u.scheme.startsWith('http') || u.host.isEmpty) return true;
  final port = u.hasPort ? u.port : (u.scheme == 'https' ? 443 : 80);
  try {
    final s = await Socket.connect(u.host, port, timeout: timeout);
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// تشخيص كامل: يصنّف النص ثم يفرّق بين «لا إنترنت» و«السيرفر متوقف» بفحص حقيقي
Future<PlayerDiagnosis> diagnosePlayerError(String raw, String url) async {
  var d = classifyPlayerError(raw);
  final ambiguous = d.kind == PlayerFailure.networkUnavailable ||
      d.kind == PlayerFailure.timeout ||
      d.kind == PlayerFailure.playbackFailure ||
      (d.kind == PlayerFailure.serverUnavailable && d.httpCode == null);
  if (!ambiguous) return d;

  if (!await hasInternet()) return PlayerDiagnosis(PlayerFailure.networkUnavailable, raw);
  // الإنترنت يعمل: إذن إما السيرفر متوقف أو الخطأ في البث نفسه
  if (d.kind == PlayerFailure.networkUnavailable || d.kind == PlayerFailure.playbackFailure) {
    if (!await serverReachable(url)) return PlayerDiagnosis(PlayerFailure.serverUnavailable, raw);
    if (d.kind == PlayerFailure.networkUnavailable) d = PlayerDiagnosis(PlayerFailure.serverUnavailable, raw);
  }
  return d;
}

/// يخفي بيانات الدخول من الرابط قبل عرضه في «معلومات البث»
String maskUrl(String url) => url
    .replaceAllMapped(RegExp(r'/(live|movie|series)/[^/]+/[^/]+/'), (m) => '/${m[1]}/•••/•••/')
    .replaceAllMapped(RegExp(r'(username|password|token)=([^&]+)', caseSensitive: false), (m) => '${m[1]}=•••')
    .replaceFirst(RegExp(r'//[^/@]+@'), '//');

/// سياسة إعادة الاتصال: تأخير متزايد وعدد محاولات محدود (لا حلقات لا نهائية)
class ReconnectPolicy {
  ReconnectPolicy({this.delays = const [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
  ]});

  final List<Duration> delays;
  int _n = 0;

  int get attempt => _n;
  int get max => delays.length;
  bool get exhausted => _n >= delays.length;

  /// التأخير التالي، أو null عند استنفاد المحاولات
  Duration? next() => exhausted ? null : delays[_n++];
  void reset() => _n = 0;
}
