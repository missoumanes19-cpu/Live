import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

const Map<String, String> _en = {
  'السيرفر': 'Server', 'البث المباشر': 'Live TV', 'الأفلام': 'Movies',
  'المسلسلات': 'Series', 'المفضلة': 'Favorites', 'مشاهدة لاحقاً': 'History',
  'الإعدادات': 'Settings', 'ابحث عن محتوى...': 'Search...', 'قناة': 'channels',
  'اللغة': 'Language', 'المشغّل': 'Player', 'وضع فك التشفير': 'Decoder mode',
  'تلقائي': 'Auto', 'عتاد (Hardware)': 'Hardware', 'برمجي (Software)': 'Software',
  'نسبة العرض الافتراضية': 'Default aspect ratio', 'احتواء': 'Fit',
  'ملء الشاشة': 'Fill screen', 'تمديد': 'Stretch', 'الحجم الأصلي': 'Original',
  'حجم الذاكرة المؤقتة': 'Buffer size', 'التحديث التلقائي من GitHub': 'Auto-update from GitHub',
  'الرقابة الأبوية': 'Parental control', 'مسح الذاكرة المؤقتة': 'Clear cache',
  'تم مسح الذاكرة المؤقتة': 'Cache cleared', 'عام': 'General', 'حول التطبيق': 'About',
  'ANES TV • السيرفرات': 'ANES TV • Servers', 'اختر مصدر القنوات': 'Choose a channel source',
  'ملف M3U': 'M3U', 'السيرفر الأونلاين • GitHub': 'Online server • GitHub',
  'اتصال وتحميل القنوات': 'Connect and load channels', 'جارٍ الاتصال...': 'Connecting...',
  'فشل الاتصال': 'Connection failed', 'رابط السيرفر / Host': 'Server URL / Host',
  'اسم المستخدم': 'Username', 'كلمة المرور': 'Password', 'رابط M3U': 'M3U link',
  'اختيار ملف M3U / M3U8': 'Pick M3U / M3U8 file', 'رابط GitHub Raw لملف JSON': 'GitHub Raw JSON link',
  'حفظ وتحديث الآن': 'Save and update now', 'آخر تحديث': 'Last update',
  'لم يتم التحديث بعد': 'Not updated yet', 'تم تحديث القنوات من GitHub': 'Channels updated from GitHub',
  'إعادة المحاولة': 'Retry', 'تبديل وضع فك التشفير': 'Switch decoder',
  'تغيير نسبة العرض': 'Change aspect ratio', 'المصدر الحالي': 'Current source',
  'لا يوجد مصدر': 'No source yet', 'متصل': 'Connected',
  'الصوت والترجمة': 'Audio & subtitles', 'الصوت': 'Audio', 'الترجمة': 'Subtitles',
  'إيقاف': 'Off', 'نسبة العرض': 'Aspect ratio', 'مؤقّت النوم': 'Sleep timer',
  'يتوفر تحديث للتطبيق': 'App update available', 'حدّث التطبيق إلى آخر إصدار': 'Please update the app',
  'أضيفت إلى المفضلة': 'Added to favorites', 'أزيلت من المفضلة': 'Removed from favorites',
  'تشخيص الاتصال': 'Connection diagnostics', 'إخفاء تصنيفات': 'Hide categories',
  'السيرفرات المحفوظة': 'Saved servers', 'بحث شامل': 'Search everything',
  'زمن الاستجابة': 'Response time', 'حالة الحساب': 'Account status',
  'تاريخ الانتهاء': 'Expiry date', 'الاتصالات المتزامنة': 'Connections',
  'اختبار': 'Run test', 'غير محدود': 'Unlimited', 'الإصدار': 'Version',
  'قائمة القنوات': 'Channels', 'ابحث في القنوات والأفلام والمسلسلات': 'Search channels, movies, series',
};

String t(String ar) => AppSettings.lang == 'en' ? (_en[ar] ?? ar) : ar;

class AppSettings extends ChangeNotifier {
  static String lang = 'ar';
  Box get _b => Hive.box('settings');

  AppSettings() { lang = (_b.get('lang', defaultValue: 'ar') as String); }

  void setLanguage(String v) { lang = v; _b.put('lang', v); notifyListeners(); }

  String get decoder => _b.get('decoder', defaultValue: 'auto') as String; // auto | hw | sw
  void setDecoder(String v) { _b.put('decoder', v); notifyListeners(); }
  static String hwdec(String d) =>
      d == 'hw' ? 'mediacodec-copy' : d == 'sw' ? 'no' : 'auto-safe';

  int get fit => _b.get('fit', defaultValue: 0) as int; // 0..3
  void setFit(int v) { _b.put('fit', v); notifyListeners(); }

  int get bufferMb => _b.get('bufferMb', defaultValue: 32) as int;
  void setBufferMb(int v) { _b.put('bufferMb', v); notifyListeners(); }

  Set<String> get hidden => Set<String>.from(
      (_b.get('hidden', defaultValue: <dynamic>[]) as List).map((e) => '$e'));
  void toggleHidden(String c) {
    final s = hidden;
    s.contains(c) ? s.remove(c) : s.add(c);
    _b.put('hidden', s.toList());
    notifyListeners();
  }

  bool get autoSync => _b.get('autoSync', defaultValue: true) as bool;
  void setAutoSync(bool v) { _b.put('autoSync', v); notifyListeners(); }
}
