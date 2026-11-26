import 'package:flutter_test/flutter_test.dart';
import 'package:anes_tv/services/download_manager.dart';
import 'package:anes_tv/services/errors.dart';
import 'package:anes_tv/services/iptv_service.dart';
import 'package:anes_tv/services/local_proxy.dart';
import 'package:anes_tv/services/server_connector.dart';
import 'package:anes_tv/services/subtitle_file.dart';
import 'package:anes_tv/services/subtitle_translator.dart';
import 'package:anes_tv/services/update_checker.dart';

void main() {
  group('M3U', () {
    test('يقرأ القنوات والمجموعات والشعارات', () {
      const m3u = '#EXTM3U\n'
          '#EXTINF:-1 tvg-id="a1" tvg-name="Channel A" tvg-logo="http://x/a.png" group-title="News",Channel A\n'
          'http://host/live/1.ts\n'
          '#EXTINF:-1 group-title="Sports",Channel B\n'
          'http://host/live/2.m3u8\n';
      final ch = IptvService().parseM3u(m3u);
      expect(ch.length, 2);
      expect(ch[0].name, 'Channel A');
      expect(ch[0].group, 'News');
      expect(ch[0].logo, 'http://x/a.png');
      expect(ch[1].group, 'Sports');
      expect(ch[1].url, 'http://host/live/2.m3u8');
    });

    test('ملف فارغ أو بلا روابط يرجع قائمة فارغة', () {
      expect(IptvService().parseM3u(''), isEmpty);
      expect(IptvService().parseM3u('#EXTM3U\n#EXTINF:-1,Only name\n'), isEmpty);
    });
  });

  group('الترجمة', () {
    test('srt', () {
      const srt = '1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld\nline2\n';
      final cues = parseSubtitle(srt, 'srt');
      expect(cues.length, 2);
      expect(cues[0].start, const Duration(seconds: 1));
      expect(cues[0].end, const Duration(seconds: 2, milliseconds: 500));
      expect(cues[1].text, contains('World'));
    });

    test('vtt بصيغة mm:ss', () {
      const vtt = 'WEBVTT\n\n00:01.000 --> 00:02.000\nHi\n';
      final cues = parseSubtitle(vtt, 'vtt');
      expect(cues.length, 1);
      expect(cues[0].start, const Duration(seconds: 1));
    });

    test('ass', () {
      const ass = '[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
          'Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\i1}Hello\\NWorld\n';
      final cues = parseSubtitle(ass, 'ass');
      expect(cues.length, 1);
      expect(cues[0].text.contains('{'), isFalse);
    });

    test('toSrt يعيد الكتابة بترقيم صحيح', () {
      final cues = parseSubtitle('1\n00:00:01,000 --> 00:00:02,000\nA\n', 'srt');
      final out = toSrt(cues);
      expect(out, contains('1\n00:00:01,000 --> 00:00:02,000\nA'));
    });

    test('clean يزيل الوسوم ويدمج الأسطر', () {
      expect(SubtitleTranslator.clean('<i>Hello</i>\nWorld {\\an8}'), 'Hello World');
    });
  });

  group('السيرفرات والإصدارات', () {
    test('versionLess', () {
      expect(ServerConnector.versionLess('1.2.0', '1.3.0'), isTrue);
      expect(ServerConnector.versionLess('1.3.0', '1.3.0'), isFalse);
      expect(ServerConnector.versionLess('1.3.0.4', '1.3.0.12'), isTrue);
      expect(ServerConnector.versionLess('2.0.0', '1.9.9'), isFalse);
    });

    test('normalHost', () {
      expect(ServerConnector.normalHost('arox.tv:80/'), 'http://arox.tv:80');
      expect(ServerConnector.normalHost('https://a.b'), 'https://a.b');
      expect(() => ServerConnector.normalHost('  '), throwsException);
    });

    test('روابط ملف الإعدادات من GitHub', () {
      final raw = ServerConnector.configCandidates('https://github.com/u/Live/blob/main/xtream_config.json');
      expect(raw.first, 'https://raw.githubusercontent.com/u/Live/main/xtream_config.json');
      expect(raw.any((e) => e.contains('cdn.jsdelivr.net')), isTrue);
      expect(ServerConnector.configCandidates('https://example.com/c.json'), ['https://example.com/c.json']);
    });

    test('استخراج المستودع من رابط الإعدادات', () {
      final r = repoFromConfigUrl('https://raw.githubusercontent.com/u/Live/main/xtream_config.json');
      expect(r?.user, 'u');
      expect(r?.repo, 'Live');
      expect(repoFromConfigUrl('https://example.com/x.json'), isNull);
    });
  });

  group('أخرى', () {
    test('معرّف التنزيل ثابت ومختلف حسب الرابط', () {
      expect(DownloadManager.idFor('http://a/1.mp4'), DownloadManager.idFor('http://a/1.mp4'));
      expect(DownloadManager.idFor('http://a/1.mp4'), isNot(DownloadManager.idFor('http://a/2.mp4')));
      expect(DownloadManager.idFor('http://a/1.mp4').length, 16);
    });

    test('friendlyError', () {
      expect(friendlyError(Exception('HTTP 401')), contains('بيانات الدخول'));
      expect(friendlyError(Exception('TimeoutException after 0:00:20')), contains('لا يستجيب'));
    });

    test('withRetry يعيد المحاولة ثم ينجح', () async {
      var n = 0;
      final v = await withRetry(() async { if (++n < 2) throw Exception('network'); return 7; }, tries: 3);
      expect(v, 7);
      expect(n, 2);
    });

    test('withRetry لا يعيد عند خطأ الدخول', () async {
      var n = 0;
      await expectLater(withRetry(() async { n++; throw Exception('Xtream HTTP 401'); }, tries: 3), throwsException);
      expect(n, 1);
    });
  });

  group('HLS proxy', () {
    test('يعيد كتابة المقاطع والمفاتيح عبر الوسيط', () {
      const body = '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\nseg1.ts\nhttp://other/x.ts\n';
      final out = rewriteM3u8(body, Uri.parse('http://h/a/b.m3u8'), (u) => '<$u>');
      expect(out,
          '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="<http://h/a/key.bin>"\n<http://h/a/seg1.ts>\n<http://other/x.ts>\n');
    });
  });
}
