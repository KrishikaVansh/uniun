import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/data/models/event_queue_model.dart';
import 'package:uniun/data/models/notes/media_attachment.dart';
import 'package:uniun/domain/entities/media/media_blob_entity.dart';
import 'package:uniun/domain/entities/media/media_dim.dart';

import '../../_helpers/fixtures.dart';
import '../../_helpers/isar_seeds.dart';

Map<String, dynamic> _payload(String serialized) =>
    (jsonDecode(serialized) as List)[1] as Map<String, dynamic>;

List<List<String>> _tags(String serialized) =>
    (_payload(serialized)['tags'] as List)
        .map((t) => (t as List).cast<String>())
        .toList();

MediaAttachment _att({
  String sha = 'sha',
  String mime = 'image/png',
  int size = 0,
  String? url,
  int? w,
  int? h,
  String? blurhash,
  String? name,
}) => MediaAttachment()
  ..sha256 = sha
  ..mime = mime
  ..sizeBytes = size
  ..url = url
  ..width = w
  ..height = h
  ..blurhash = blurhash
  ..filename = name;

/// Covers: canonical tag order across every optional slot, NIP-10 marker
/// de-duplication of root/reply inside eTagRefs, imeta field presence rules,
/// relay-message envelope (seconds timestamp), and the two populate methods.
void main() {
  group('toSerializedRelayMessage', () {
    test(
      'wraps the event in an EVENT frame with second-resolution created_at',
      () {
        final row = eventQueueRow(
          'id1',
          authorPubkey: 'pk',
          sig: 'sg',
          content: 'héllo 🌍',
          created: DateTime.fromMillisecondsSinceEpoch(
            1_700_000_123_456,
            isUtc: true,
          ),
        );
        final decoded = jsonDecode(row.toSerializedRelayMessage()) as List;
        expect(decoded[0], 'EVENT');
        final p = decoded[1] as Map<String, dynamic>;
        expect(p['id'], 'id1');
        expect(p['pubkey'], 'pk');
        expect(p['sig'], 'sg');
        expect(p['kind'], 1);
        expect(p['content'], 'héllo 🌍');
        expect(p['created_at'], 1_700_000_123);
        expect(p['tags'], isEmpty);
      },
    );

    test('emits every optional slot in the documented canonical order', () {
      final row = eventQueueRow(
        'id',
        rootEventId: 'root',
        replyToEventId: 'reply',
        eTagRefs: ['root', 'reply', 'm1'],
        pTagRefs: ['p1'],
        tTags: ['topic'],
        hTag: 'grp',
        dTag: 'draft',
        quoteKind: 1,
        embeddedNoteJson: '{"x":1}',
        expirationSec: 99,
        serverTags: ['https://s1'],
        imeta: [_att(url: 'https://u/a.png')],
      );
      final tags = _tags(row.toSerializedRelayMessage());
      expect(tags.map((t) => t.first).toList(), [
        'e',
        'e',
        'e',
        'p',
        't',
        'h',
        'd',
        'k',
        'embeddedNoteJson',
        'expiration',
        'server',
        'imeta',
      ]);
      expect(tags[0], ['e', 'root', '', 'root']);
      expect(tags[1], ['e', 'reply', '', 'reply']);
      expect(tags[2], ['e', 'm1', '', 'mention']);
      expect(tags[7], ['k', '1']);
      expect(tags[9], ['expiration', '99']);
    });

    test('root without reply emits only the root marker', () {
      final row = eventQueueRow('id', rootEventId: 'r', eTagRefs: ['r']);
      expect(_tags(row.toSerializedRelayMessage()), [
        ['e', 'r', '', 'root'],
      ]);
    });

    test('plain e refs with no thread markers are all mentions', () {
      final row = eventQueueRow('id', eTagRefs: ['a', 'b']);
      expect(_tags(row.toSerializedRelayMessage()), [
        ['e', 'a', '', 'mention'],
        ['e', 'b', '', 'mention'],
      ]);
    });

    test('imeta carries only the fields that are set', () {
      final minimal = eventQueueRow(
        'id',
        imeta: [_att(sha: 'abc', mime: 'application/pdf')],
      );
      expect(_tags(minimal.toSerializedRelayMessage()).single, [
        'imeta',
        'm application/pdf',
        'x abc',
      ]);

      final full = eventQueueRow(
        'id',
        imeta: [
          _att(
            sha: 'abc',
            url: 'https://u',
            size: 10,
            w: 4,
            h: 3,
            blurhash: 'LEH',
            name: 'a b.png',
          ),
        ],
      );
      expect(_tags(full.toSerializedRelayMessage()).single, [
        'imeta',
        'url https://u',
        'm image/png',
        'x abc',
        'size 10',
        'dim 4x3',
        'blurhash LEH',
        'name a b.png',
      ]);
    });

    test(
      'imeta omits dim when only one side is known and skips empty names',
      () {
        final row = eventQueueRow('id', imeta: [_att(w: 4, name: '')]);
        expect(_tags(row.toSerializedRelayMessage()).single, [
          'imeta',
          'm image/png',
          'x sha',
        ]);
      },
    );

    test('repeated server and topic tags keep their insertion order', () {
      final row = eventQueueRow(
        'id',
        tTags: ['z', 'a'],
        serverTags: ['s2', 's1'],
      );
      expect(_tags(row.toSerializedRelayMessage()), [
        ['t', 'z'],
        ['t', 'a'],
        ['server', 's2'],
        ['server', 's1'],
      ]);
    });
  });

  group('populate', () {
    test(
      'populateFromNoteModel copies fields, resets sentCount, copies lists',
      () {
        final note = noteRow(
          'n1',
          content: 'body',
          eTagRefs: ['x'],
          pTagRefs: ['p'],
          tTags: ['t'],
          rootEventId: 'r',
          replyToEventId: 'rp',
          embeddedNoteJson: '{}',
          attachments: [_att(url: 'u')],
        );
        final row = EventQueueModel()..sentCount = 5;
        final before = DateTime.now();
        row.populateFromNoteModel(note);

        expect(row.eventId, 'n1');
        expect(row.kind, 1);
        expect(row.content, 'body');
        expect(row.rootEventId, 'r');
        expect(row.replyToEventId, 'rp');
        expect(row.embeddedNoteJson, '{}');
        expect(row.imeta, hasLength(1));
        expect(row.sentCount, 0);
        expect(row.enqueuedAt.isBefore(before), isFalse);
        row.eTagRefs.add('mutated');
        expect(note.eTagRefs, ['x']);
      },
    );

    test(
      'populateFromNoteEntity drops thread markers and maps attachments',
      () {
        final entity = aNote(
          id: 'e1',
          eTagRefs: ['a'],
          rootEventId: 'ignored',
          attachments: const [
            MediaBlobEntity(
              sha256: 'h1',
              mime: 'image/jpeg',
              sizeBytes: 7,
              dim: MediaDim(width: 2, height: 3),
              blurhash: 'bh',
              filename: 'f.jpg',
              serverUrls: ['https://first', 'https://second'],
            ),
            MediaBlobEntity(sha256: 'h2', mime: 'image/png', sizeBytes: 0),
          ],
        );
        final row = EventQueueModel()..populateFromNoteEntity(entity);

        expect(row.rootEventId, isNull);
        expect(row.replyToEventId, isNull);
        expect(row.eTagRefs, ['a']);
        expect(row.imeta, hasLength(2));
        final a = row.imeta[0];
        expect(
          [
            a.sha256,
            a.mime,
            a.sizeBytes,
            a.url,
            a.width,
            a.height,
            a.blurhash,
            a.filename,
          ],
          ['h1', 'image/jpeg', 7, 'https://first', 2, 3, 'bh', 'f.jpg'],
        );
        final b = row.imeta[1];
        expect([b.url, b.width, b.height], [null, null, null]);
      },
    );
  });
}
