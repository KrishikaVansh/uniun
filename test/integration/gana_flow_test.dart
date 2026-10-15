import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/core/enum/gana_output_type.dart';
import 'package:uniun/core/enum/gana_run_status.dart';
import 'package:uniun/core/enum/gana_trigger_mode.dart';
import 'package:uniun/data/repositories/gana_repository_impl.dart';
import 'package:uniun/data/repositories/gana_run_repository_impl.dart';
import 'package:uniun/domain/entities/gana/gana_run_entity.dart';
import 'package:uniun/domain/entities/llm/llm_backend_type.dart';
import 'package:uniun/features/mesh/sync/mesh_event_signer.dart';

import '../_helpers/fixtures.dart';
import '../_helpers/isar_test_harness.dart';
import '../_helpers/stub_user_repository.dart';

/// End-to-end Gana CRUD + cursor + run-log lifecycle — create → enable
/// toggle → cursor advance → run log → tombstone delete (which purges the
/// local run log in the same txn). Real Isar + real `GanaRepositoryImpl`/
/// `GanaRunRepositoryImpl`; only identity (mesh signing) is stubbed, same
/// pattern as `dm_flow_test.dart`. Does NOT exercise `GanaEngine` itself
/// (inference/publish) — that needs `flutter_edge_ai`/network, which is
/// covered separately by `test/features/shiv/gana/engine/gana_engine_test.dart`
/// (mocked collaborators) and the device-bound `integration_test/
/// gana_cloud_engine_e2e_test.dart` / `gana_local_engine_e2e_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Isar isar;
  late GanaRepositoryImpl ganas;
  late GanaRunRepositoryImpl runs;

  setUp(() async {
    isar = await openTestIsar();
    ganas = GanaRepositoryImpl(
      isar: isar,
      signer: MeshEventSigner(StubUserRepository()..keys = null),
    );
    runs = GanaRunRepositoryImpl(isar: isar);
  });

  tearDown(() async {
    await isar.close(deleteFromDisk: true);
  });

  test(
      'SCENARIO: create → appears enabled → getGanaById round-trips every '
      'field, including the cloud pin', () async {
    final created = await ganas.upsertGana(aGana(
      ganaId: 'g-1',
      name: 'Digest bot',
      manasIds: const ['m-1', 'm-2'],
      outputType: GanaOutputType.group,
      outputGroupId: 'group-abc',
      desiredModelId: 'claude-cloud-mini',
      desiredBackend: LlmBackendType.uniunCloud,
      triggerMode: GanaTriggerMode.oneShot,
      enabled: true,
    ));
    expect(created.isRight(), isTrue);

    final fetched = (await ganas.getGanaById('g-1')).getOrElse(
        () => throw StateError('unreachable'));
    expect(fetched.name, 'Digest bot');
    expect(fetched.manasIds, ['m-1', 'm-2']);
    expect(fetched.outputType, GanaOutputType.group);
    expect(fetched.outputGroupId, 'group-abc');
    expect(fetched.desiredModelId, 'claude-cloud-mini');
    expect(fetched.desiredBackend, LlmBackendType.uniunCloud);
    expect(fetched.triggerMode, GanaTriggerMode.oneShot);

    final enabledList =
        (await ganas.getEnabledGanas()).getOrElse(() => const []);
    expect(enabledList.map((g) => g.ganaId), ['g-1']);
  });

  test(
      'SCENARIO: a disabled Gana is excluded from getEnabledGanas but still '
      'appears in getGanas', () async {
    await ganas.upsertGana(aGana(ganaId: 'g-off', enabled: false));

    final all = (await ganas.getGanas()).getOrElse(() => const []);
    final enabled = (await ganas.getEnabledGanas()).getOrElse(() => const []);
    expect(all.map((g) => g.ganaId), ['g-off']);
    expect(enabled, isEmpty);
  });

  test(
      'SCENARIO: re-upserting the same ganaId updates fields but preserves '
      'cursor state the new entity omits', () async {
    await ganas.upsertGana(aGana(ganaId: 'g-2', name: 'v1'));
    await ganas.advanceCursor(
      ganaId: 'g-2',
      lastProcessedEventId: 'evt-100',
      lastProcessedCreated: DateTime(2026, 1, 1),
      lastRunAt: DateTime(2026, 1, 1),
    );

    // Rename via a fresh entity that carries no cursor fields at all.
    await ganas.upsertGana(aGana(ganaId: 'g-2', name: 'v2'));

    final fetched = (await ganas.getGanaById('g-2'))
        .getOrElse(() => throw StateError('unreachable'));
    expect(fetched.name, 'v2');
    expect(fetched.lastProcessedEventId, 'evt-100');
  });

  test(
      'SCENARIO: setEnabled toggles reflect immediately in getEnabledGanas',
      () async {
    await ganas.upsertGana(aGana(ganaId: 'g-3', enabled: false));
    expect((await ganas.getEnabledGanas()).getOrElse(() => const []), isEmpty);

    await ganas.setEnabled('g-3', true);
    expect(
        (await ganas.getEnabledGanas()).getOrElse(() => const []).map((g) => g.ganaId),
        ['g-3']);

    await ganas.setEnabled('g-3', false);
    expect((await ganas.getEnabledGanas()).getOrElse(() => const []), isEmpty);
  });

  test('SCENARIO: setEnabled on an unknown ganaId fails with notFound',
      () async {
    final result = await ganas.setEnabled('ghost', true);
    expect(result.isLeft(), isTrue);
  });

  test(
      'SCENARIO: run log lifecycle — log a run, list it, and resolve its '
      'self-output guard set', () async {
    await ganas.upsertGana(aGana(ganaId: 'g-4', enabled: true));

    await runs.logRun(GanaRunEntity(
      runId: 'r-1',
      ganaId: 'g-4',
      startedAt: DateTime(2026, 1, 1, 10),
      status: GanaRunStatus.succeeded,
      inputEventIds: const ['in-1'],
      outputEventId: 'out-1',
    ));
    await runs.logRun(GanaRunEntity(
      runId: 'r-2',
      ganaId: 'g-4',
      startedAt: DateTime(2026, 1, 1, 11),
      status: GanaRunStatus.skipped,
      skipReason: GanaSkipReason.noNewInput,
    ));

    final list = (await runs.getRunsFor('g-4')).getOrElse(() => const []);
    expect(list.map((r) => r.runId).toList(), ['r-2', 'r-1']); // newest first

    final outputs =
        (await runs.getOutputEventIdsFor('g-4')).getOrElse(() => const {});
    expect(outputs, {'out-1'});
  });

  test(
      'SCENARIO: deleting a Gana tombstones it (gone from getGanas) AND '
      'purges its local run log in the same operation', () async {
    await ganas.upsertGana(aGana(ganaId: 'g-5', enabled: true));
    await runs.logRun(GanaRunEntity(
      runId: 'r-a',
      ganaId: 'g-5',
      startedAt: DateTime(2026, 1, 1),
      status: GanaRunStatus.succeeded,
      outputEventId: 'evt-a',
    ));
    expect((await runs.getRunsFor('g-5')).getOrElse(() => const []),
        hasLength(1));

    await ganas.deleteGana('g-5');

    expect((await ganas.getGanas()).getOrElse(() => const []), isEmpty);
    expect(
        (await ganas.getGanaById('g-5')).isLeft(), isTrue); // notFound now
    expect((await runs.getRunsFor('g-5')).getOrElse(() => const []), isEmpty);
  });

  test('SCENARIO: deleting an unknown ganaId is a harmless no-op', () async {
    final result = await ganas.deleteGana('never-existed');
    expect(result.isRight(), isTrue);
  });

  // ── Edge cases ────────────────────────────────────────────────────────────

  test('EDGE: pruneOldRuns trims each Gana down to its keep cap, newest first',
      () async {
    await ganas.upsertGana(aGana(ganaId: 'g-prune', enabled: true));
    for (var i = 0; i < 5; i++) {
      await runs.logRun(GanaRunEntity(
        runId: 'r-$i',
        ganaId: 'g-prune',
        startedAt: DateTime(2026, 1, 1).add(Duration(minutes: i)),
        status: GanaRunStatus.succeeded,
      ));
    }

    await runs.pruneOldRuns(keepPerGana: 2, globalCap: 1000);

    final remaining =
        (await runs.getRunsFor('g-prune', limit: 100)).getOrElse(() => const []);
    expect(remaining.map((r) => r.runId).toList(), ['r-4', 'r-3']);
  });

  test(
      'EDGE: unicode/emoji in name and taskPrompt round-trip through Isar '
      'unchanged', () async {
    await ganas.upsertGana(aGana(
      ganaId: 'g-unicode',
      name: '日本語ボット 🤖',
      taskPrompt: Content.unicode,
    ));
    final fetched = (await ganas.getGanaById('g-unicode'))
        .getOrElse(() => throw StateError('unreachable'));
    expect(fetched.name, '日本語ボット 🤖');
    expect(fetched.taskPrompt, Content.unicode);
  });

  test('EDGE: a cloud pin with a null desiredModelId is a valid, if inert, '
      'combination — round-trips as-is (the engine gate treats it as '
      'cloudUnavailable, not a persistence error)', () async {
    await ganas.upsertGana(aGana(
      ganaId: 'g-null-model',
      desiredBackend: LlmBackendType.uniunCloud,
      desiredModelId: null,
    ));
    final fetched = (await ganas.getGanaById('g-null-model'))
        .getOrElse(() => throw StateError('unreachable'));
    expect(fetched.desiredBackend, LlmBackendType.uniunCloud);
    expect(fetched.desiredModelId, isNull);
  });

  test('EDGE: 30 Ganas — getGanas returns all, newest-updated first',
      () async {
    for (var i = 0; i < 30; i++) {
      await ganas.upsertGana(aGana(
        ganaId: 'g-scale-$i',
        updatedAt: DateTime(2026, 1, 1).add(Duration(minutes: i)),
      ));
    }
    final all = (await ganas.getGanas()).getOrElse(() => const []);
    expect(all, hasLength(30));
    expect(all.first.ganaId, 'g-scale-29'); // most recently updated first
  });
}
