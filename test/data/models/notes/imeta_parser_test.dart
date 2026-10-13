import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/data/models/notes/imeta_parser.dart';

Map<String, dynamic> _ev(List<dynamic> tags) => {'tags': tags};

/// Covers: full tag parse, defaults, dropped malformed tags (no url/sha, empty
/// values, non-list, non-string parts), dim edge cases, unknown keys, multiple
/// tags, and the attachment mapping.
void main() {
  test('parses every supported field', () {
    final out = ImetaParser.parse(
      _ev([
        [
          'imeta',
          'url https://b/x.png',
          'x abc123',
          'm image/png',
          'size 2048',
          'dim 640x480',
          'blurhash LEHV6n',
          'name my pic.png',
        ],
      ]),
    );
    expect(out, hasLength(1));
    final t = out.single;
    expect(t.url, 'https://b/x.png');
    expect(t.sha256, 'abc123');
    expect(t.mime, 'image/png');
    expect(t.sizeBytes, 2048);
    expect([t.width, t.height], [640, 480]);
    expect(t.blurhash, 'LEHV6n');
    expect(t.filename, 'my pic.png');
  });

  test('mime defaults to octet-stream and optional fields are null', () {
    final t = ImetaParser.parse(
      _ev([
        ['imeta', 'url u', 'x h'],
      ]),
    ).single;
    expect(t.mime, 'application/octet-stream');
    expect(
      [t.sizeBytes, t.width, t.height, t.blurhash, t.filename],
      [null, null, null, null, null],
    );
  });

  test('tags missing a url or a hash are dropped', () {
    final out = ImetaParser.parse(
      _ev([
        ['imeta', 'x onlyhash'],
        ['imeta', 'url onlyurl'],
        ['imeta', 'm image/png'],
      ]),
    );
    expect(out, isEmpty);
  });

  test('non-imeta, empty, non-list and bad-typed parts are skipped', () {
    final out = ImetaParser.parse(
      _ev([
        ['t', 'topic'],
        [],
        'not-a-list',
        ['imeta', 7, null, 'url u', 'x h'],
        ['imeta', 'novalue', 'url   ', ' leadingspace v'],
      ]),
    );
    expect(out, hasLength(1));
    expect(out.single.url, 'u');
  });

  test('malformed dim and size values yield nulls, not exceptions', () {
    final t = ImetaParser.parse(
      _ev([
        ['imeta', 'url u', 'x h', 'dim 100', 'size big'],
      ]),
    ).single;
    expect([t.width, t.height, t.sizeBytes], [null, null, null]);

    final t2 = ImetaParser.parse(
      _ev([
        ['imeta', 'url u', 'x h', 'dim axb', 'dim 1x2x3'],
      ]),
    ).single;
    expect(t2.width, isNull);
  });

  test('a later duplicate key wins and unknown keys are ignored', () {
    final t = ImetaParser.parse(
      _ev([
        [
          'imeta',
          'url first',
          'url second',
          'x h',
          'alt some text',
          'fallback z',
        ],
      ]),
    ).single;
    expect(t.url, 'second');
  });

  test('missing or null tags yield an empty list', () {
    expect(ImetaParser.parse(<String, dynamic>{}), isEmpty);
    expect(ImetaParser.parse({'tags': null}), isEmpty);
  });

  test('multiple imeta tags keep their order', () {
    final out = ImetaParser.parse(
      _ev([
        ['imeta', 'url a', 'x 1'],
        ['p', 'pub'],
        ['imeta', 'url b', 'x 2'],
      ]),
    );
    expect(out.map((t) => t.url), ['a', 'b']);
  });

  test('parseAsAttachments maps fields and zeroes a missing size', () {
    final atts = ImetaParser.parseAsAttachments(
      _ev([
        ['imeta', 'url u', 'x h', 'm video/mp4', 'dim 10x20', 'name v.mp4'],
      ]),
    );
    expect(atts, hasLength(1));
    final a = atts.single;
    expect(a.sha256, 'h');
    expect(a.mime, 'video/mp4');
    expect(a.sizeBytes, 0);
    expect(a.url, 'u');
    expect([a.width, a.height], [10, 20]);
    expect(a.filename, 'v.mp4');
    expect(a.blurhash, isNull);
  });
}
