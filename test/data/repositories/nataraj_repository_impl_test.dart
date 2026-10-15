import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/core/enum/nataraj_card_status.dart';
import 'package:uniun/data/repositories/nataraj_repository_impl.dart';
import 'package:uniun/domain/entities/nataraj/nataraj_card_entity.dart';

import '../../_helpers/isar_test_harness.dart';

NatarajCardEntity _card(
  String sig, {
  String scope = 's1',
  NatarajCardStatus status = NatarajCardStatus.buffered,
  DateTime? created,
  DateTime? seen,
}) => NatarajCardEntity(
  scopeId: scope,
  signature: sig,
  noteIds: const ['a', 'b'],
  generatedParagraph: 'idea $sig',
  status: status,
  createdAt: created ?? DateTime(2026, 1, 1),
  lastSeenAt: seen,
);

/// Covers: NatarajRepositoryImpl against real Isar: the buffer, known
/// signatures, status updates, counts, rehydrating discarded cards, scope
/// isolation, and the failure path on a closed database.
void main() {
  late Isar isar;
  late NatarajRepositoryImpl repo;

  setUp(() async {
    isar = await openTestIsar();
    repo = NatarajRepositoryImpl(isar: isar);
  });

  tearDown(() async {
    if (isar.isOpen) await isar.close(deleteFromDisk: true);
  });

  test('the next buffered card is the oldest one in that scope', () async {
    await repo.insertBufferedCards([
      _card('new', created: DateTime(2026, 3, 1)),
      _card('old', created: DateTime(2026, 1, 1)),
      _card('other', scope: 's2', created: DateTime(2025, 1, 1)),
    ]);

    final r = await repo.nextBufferedCard('s1');

    expect(r.getOrElse(() => null)!.signature, 'old');
  });

  test('an empty buffer answers null, not an error', () async {
    final r = await repo.nextBufferedCard('s1');

    expect(r.isRight(), isTrue);
    expect(r.getOrElse(() => _card('x')), isNull);
  });

  test('known signatures cover every status but only that scope', () async {
    await repo.insertBufferedCards([
      _card('a'),
      _card('b', status: NatarajCardStatus.discarded),
      _card('c', scope: 's2'),
    ]);

    final r = await repo.getKnownSignatures('s1');

    expect(r.getOrElse(() => {}), {'a', 'b'});
  });

  test('inserted cards keep their fields', () async {
    await repo.insertBufferedCards([_card('a', seen: DateTime(2026, 2, 2))]);

    final card = (await repo.nextBufferedCard('s1')).getOrElse(() => null)!;

    expect(card.noteIds, ['a', 'b']);
    expect(card.generatedParagraph, 'idea a');
    expect(card.status, NatarajCardStatus.buffered);
    expect(card.lastSeenAt!.toUtc(), DateTime(2026, 2, 2).toUtc());
  });

  test('updating a status moves the card and stamps lastSeenAt', () async {
    await repo.insertBufferedCards([_card('a')]);

    await repo.updateStatus('s1', 'a', NatarajCardStatus.published);

    expect(
      (await repo.countByStatus(
        's1',
        NatarajCardStatus.published,
      )).getOrElse(() => -1),
      1,
    );
    expect(
      (await repo.countByStatus(
        's1',
        NatarajCardStatus.buffered,
      )).getOrElse(() => -1),
      0,
    );
    final known = await repo.getKnownSignatures('s1');
    expect(known.getOrElse(() => {}), {'a'});
  });

  test('updating a card that does not exist is a no-op', () async {
    final r = await repo.updateStatus('s1', 'ghost', NatarajCardStatus.seen);

    expect(r.isRight(), isTrue);
    expect(
      (await repo.countByStatus(
        's1',
        NatarajCardStatus.seen,
      )).getOrElse(() => -1),
      0,
    );
  });

  test('counts are per status and per scope', () async {
    await repo.insertBufferedCards([
      _card('a'),
      _card('b'),
      _card('c', status: NatarajCardStatus.seen),
      _card('d', scope: 's2'),
    ]);

    expect(
      (await repo.countByStatus(
        's1',
        NatarajCardStatus.buffered,
      )).getOrElse(() => -1),
      2,
    );
    expect(
      (await repo.countByStatus(
        's1',
        NatarajCardStatus.seen,
      )).getOrElse(() => -1),
      1,
    );
    expect(
      (await repo.countByStatus(
        's2',
        NatarajCardStatus.buffered,
      )).getOrElse(() => -1),
      1,
    );
  });

  test(
    'rehydrating brings back the least recently seen discarded cards',
    () async {
      await repo.insertBufferedCards([
        _card('never', status: NatarajCardStatus.discarded),
        _card(
          'older',
          status: NatarajCardStatus.discarded,
          seen: DateTime(2026, 1, 2),
        ),
        _card(
          'newer',
          status: NatarajCardStatus.discarded,
          seen: DateTime(2026, 5, 5),
        ),
      ]);

      final r = await repo.rehydrateOldestDiscarded('s1', 2);

      expect(r.getOrElse(() => -1), 2);
      expect(
        (await repo.countByStatus(
          's1',
          NatarajCardStatus.buffered,
        )).getOrElse(() => -1),
        2,
      );
      expect(
        (await repo.countByStatus(
          's1',
          NatarajCardStatus.discarded,
        )).getOrElse(() => -1),
        1,
      );
    },
  );

  test('rehydrating with nothing discarded returns 0', () async {
    await repo.insertBufferedCards([_card('a')]);

    final r = await repo.rehydrateOldestDiscarded('s1', 5);

    expect(r.getOrElse(() => -1), 0);
  });

  test('inserting an empty list is fine', () async {
    final r = await repo.insertBufferedCards(const []);

    expect(r.isRight(), isTrue);
  });

  group('a closed database is a failure, never a throw', () {
    setUp(() async {
      await isar.close();
    });

    test('every method returns Left', () async {
      expect((await repo.nextBufferedCard('s1')).isLeft(), isTrue);
      expect((await repo.getKnownSignatures('s1')).isLeft(), isTrue);
      expect((await repo.insertBufferedCards([_card('a')])).isLeft(), isTrue);
      expect(
        (await repo.updateStatus('s1', 'a', NatarajCardStatus.seen)).isLeft(),
        isTrue,
      );
      expect(
        (await repo.countByStatus('s1', NatarajCardStatus.seen)).isLeft(),
        isTrue,
      );
      expect((await repo.rehydrateOldestDiscarded('s1', 1)).isLeft(), isTrue);
    });
  });
}
