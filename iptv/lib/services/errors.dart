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
