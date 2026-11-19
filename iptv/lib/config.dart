/// رابط ملف الإعدادات على GitHub (Raw).
/// يُحقن تلقائياً أثناء البناء من الـ workflow عبر --dart-define=CONFIG_URL=...
class AppConfig {
  static const githubConfigUrl = String.fromEnvironment('CONFIG_URL');
  static const syncInterval = Duration(minutes: 5);
}
