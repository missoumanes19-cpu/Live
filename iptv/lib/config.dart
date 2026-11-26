/// رابط ملف الإعدادات (Raw) — يُحقن تلقائياً أثناء البناء من الـ workflow عبر --dart-define=CONFIG_URL=...
class AppConfig {
  /// يُحقن من الـ workflow: --dart-define=APP_VERSION=1.3.0.<رقم البناء>
  static const version = String.fromEnvironment('APP_VERSION', defaultValue: '1.3.0');
  static const githubConfigUrl = String.fromEnvironment('CONFIG_URL');
  static const syncInterval = Duration(minutes: 5);
}
