import 'package:flutter_hbb/mobile/pages/herdr/herdr_known_dirs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('herdrParseKnownDirs', () {
    test('parses the service body and keeps zoxide ranking order', () {
      // Shape emitted by herdr-dirs-http.sh, best first.
      const body = '{"dirs":['
          '{"path":"/home/hyt/Desktop/DEV/devdesk","score":2.0},'
          '{"path":"/home/hyt/Desktop/MAN_PC","score":0.5}'
          ']}';
      final dirs = herdrParseKnownDirs(body);
      expect(dirs.length, 2);
      expect(dirs.first.path, '/home/hyt/Desktop/DEV/devdesk');
      expect(dirs.first.score, 2.0);
      expect(dirs.last.name, 'MAN_PC');
    });

    test('skips malformed entries instead of losing the whole list', () {
      // Some suggestions beat none.
      const body = '{"dirs":['
          '{"score":1},'
          '{"path":""},'
          '"nonsense",'
          '{"path":"/home/hyt/bin"}'
          ']}';
      final dirs = herdrParseKnownDirs(body);
      expect(dirs.length, 1);
      expect(dirs.single.path, '/home/hyt/bin');
      expect(dirs.single.score, 0, reason: 'missing score is not fatal');
    });

    test('an absent or empty list is a valid answer', () {
      expect(herdrParseKnownDirs('{"dirs":[]}'), isEmpty);
      expect(herdrParseKnownDirs('{}'), isEmpty);
      expect(herdrParseKnownDirs('[]'), isEmpty);
      expect(herdrParseKnownDirs('{"dirs":"nope"}'), isEmpty);
    });

    test('name is the last segment, trailing slash and root included', () {
      expect(const HerdrKnownDir(path: '/home/hyt/Desktop/DEV').name, 'DEV');
      expect(const HerdrKnownDir(path: '/home/hyt/Desktop/DEV/').name, 'DEV');
      expect(const HerdrKnownDir(path: '/').name, '/');
    });
  });
}
