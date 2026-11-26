/// رسائل خطأ مفهومة بدل نصوص الاستثناءات الخام
String friendlyError(Object e) {
  final s = '$e';
  if (s.contains('SocketException') || s.contains('Failed host lookup') || s.contains('ClientException')) {
    return 'لا يوجد اتصال بالإنترنت أو السيرفر غير متاح';
  }
  if (s.contains('TimeoutException')) return 'السيرفر لا يستجيب، حاول لاحقاً';
  if (s.contains('401') || s.contains('403')) return 'بيانات الدخول خاطئة أو انتهى الاشتراك';
  if (s.contains('404')) return 'الرابط غير صحيح (404)';
  if (s.contains('FormatException')) return 'استجابة غير صالحة من السيرفر';
  return s.replaceFirst('Exception: ', '');
}

/// يعيد المحاولة بتأخير متزايد عند ضعف الإنترنت (لا يعيد عند أخطاء الدخول أو الرابط)
Future<T> withRetry<T>(Future<T> Function() f, {int tries = 3}) async {
  Object? last;
  for (var i = 0; i < tries; i++) {
    try {
      return await f();
    } catch (e) {
      last = e;
      final s = '$e';
      final fatal = s.contains('HTTP 401') || s.contains('HTTP 403') || s.contains('HTTP 404') ||
          s.contains('FormatException') || s.contains('بيانات الدخول');
      if (fatal || i == tries - 1) rethrow;
      await Future.delayed(Duration(milliseconds: 700 * (i + 1) * (i + 1)));
    }
  }
  throw last ?? Exception('retry');
}
