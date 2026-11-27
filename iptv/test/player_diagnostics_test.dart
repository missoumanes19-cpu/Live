import 'package:flutter_test/flutter_test.dart';
import 'package:anes_tv/services/player_diagnostics.dart';

void main() {
  group('classifyPlayerError', () {
    test('404 = رابط غير صالح ولا يُعاد المحاولة', () {
      final d = classifyPlayerError('Failed to open: HTTP error 404 Not Found');
      expect(d.kind, PlayerFailure.invalidStream);
      expect(d.httpCode, 404);
      expect(d.retryable, isFalse);
    });

    test('403 و 5xx = السيرفر غير متاح', () {
      final a = classifyPlayerError('Server returned 403 Forbidden');
      expect(a.kind, PlayerFailure.serverUnavailable);
      expect(a.message, contains('403'));
      expect(classifyPlayerError('HTTP error 503 Service Unavailable').kind, PlayerFailure.serverUnavailable);
      expect(classifyPlayerError('Server returned 5XX Server Error reply').kind, PlayerFailure.serverUnavailable);
    });

    test('انتهاء المهلة', () {
      expect(classifyPlayerError('tcp: Connection timed out').kind, PlayerFailure.timeout);
      expect(classifyPlayerError('timeout: buffering stalled for 30s').kind, PlayerFailure.timeout);
      expect(classifyPlayerError('HTTP error 504 Gateway Timeout').kind, PlayerFailure.timeout);
    });

    test('صيغة غير مدعومة / بث غير صالح', () {
      expect(classifyPlayerError('Unsupported codec').kind, PlayerFailure.unsupportedFormat);
      expect(classifyPlayerError('Failed to recognize file format.').kind, PlayerFailure.invalidStream);
    });

    test('شبكة غير متاحة', () {
      expect(classifyPlayerError('Failed to resolve hostname').kind, PlayerFailure.networkUnavailable);
      expect(classifyPlayerError('Network is unreachable').kind, PlayerFailure.networkUnavailable);
    });

    test('أي شيء آخر = فشل تشغيل قابل للمحاولة', () {
      final d = classifyPlayerError('no video output (black screen)');
      expect(d.kind, PlayerFailure.playbackFailure);
      expect(d.retryable, isTrue);
    });

    test('لكل نوع عنوان ورسالة', () {
      for (final k in PlayerFailure.values) {
        final d = PlayerDiagnosis(k, 'x');
        expect(d.title, isNotEmpty);
        expect(d.message, isNotEmpty);
      }
    });
  });

  group('ReconnectPolicy', () {
    test('تأخير متزايد ثم يتوقف (لا حلقة لا نهائية)', () {
      final p = ReconnectPolicy();
      final delays = <Duration>[];
      Duration? d;
      while ((d = p.next()) != null) {
        delays.add(d!);
        expect(delays.length, lessThan(50));
      }
      expect(delays.length, p.max);
      expect(p.exhausted, isTrue);
      expect(delays.first, lessThan(delays.last));
    });

    test('reset يعيد المحاولات', () {
      final p = ReconnectPolicy()..next()..next();
      expect(p.attempt, 2);
      p.reset();
      expect(p.attempt, 0);
      expect(p.exhausted, isFalse);
    });
  });

  test('maskUrl يخفي بيانات الدخول', () {
    expect(maskUrl('http://h:8080/live/user1/pass1/123.ts'), 'http://h:8080/live/•••/•••/123.ts');
    expect(maskUrl('http://h/get.php?username=a&password=b&type=m3u'), contains('username=•••'));
    expect(maskUrl('http://u:p@h/x.m3u8'), 'http://h/x.m3u8');
  });
}
