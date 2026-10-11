// Full end-to-end run of a LOCAL (on-device) Brahma Gana against the real app:
// real DI, the on-device Isar, the real GanaEngine and GatewayBootstrap, and a
// real flutter_gemma inference call (Gemma 4 E2B, provisioned by
// `provisionTestModel`). Verifies the published note used the seeded knowledge.
//
// SIDE EFFECT: every run publishes one real, PERMANENT Kind-1 note from the
// device's identity to the relay (Feed Freedom, no delete). The Gana, its run
// log and the note stay in local Isar; only the seeded saved note is removed.
// This file is part of all_tests.dart, so a full device run posts one too.
//
//   scripts/device_test.sh run integration_test/gana_local_engine_e2e_test.dart

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'package:flutter_gemma_mediapipe/flutter_gemma_mediapipe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/common/locator.dart';
import 'package:uniun/core/enum/gana_output_type.dart';
import 'package:uniun/core/enum/gana_run_status.dart';
import 'package:uniun/core/enum/gana_trigger_mode.dart';
import 'package:uniun/core/enum/note_type.dart';
import 'package:uniun/data/models/event_queue_model.dart';
import 'package:uniun/data/models/gana_model.dart';
import 'package:uniun/data/models/gana_run_model.dart';
import 'package:uniun/data/models/saved_note_model.dart';
import 'package:uniun/domain/entities/ai_model/ai_model_entity.dart';
import 'package:uniun/domain/repositories/user_repository.dart';
import 'package:uniun/domain/usecases/ai_model_usecases.dart';
import 'package:uniun/features/shiv/gana/engine/gana_engine.dart';
import 'package:uniun/gateway/gateway.dart';

import 'support/test_model.dart';

/// Covers a grounded Brahma Gana run through Gemma 4 E2B and relay publish.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('a local (on-device) standalone Gana runs end-to-end and reaches a real relay',
      () async {
    if (!getIt.isRegistered<Isar>()) await configureDependencies();
    final isar = getIt<Isar>();

    await FlutterGemma.initialize(
      inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
      embeddingBackends: const [LiteRtEmbeddingBackend()],
    );
    // Restore the persisted model registration before provisioning the fixture.
    await getIt<GetActiveAIModelUseCase>().call();
    expect(await provisionTestModel(AIModelId.gemma4E2b), isTrue,
        reason: 'Gemma 4 E2B fixture is required for the local Gana smoke test');

    var keys = await getIt<UserRepository>().getActiveKeysHex();
    if (keys == null) {
      final generated = await getIt<UserRepository>().generateKey();
      generated.fold(
        (failure) => fail('Could not create a test identity: $failure'),
        (_) {},
      );
      keys = await getIt<UserRepository>().getActiveKeysHex();
      expect(keys, isNotNull);
      // ignore: avoid_print
      print('provisioned a fresh identity for this run: '
          'pubkey=${keys?.pubkeyHex}');
    }

    await GatewayBootstrap.start();

    final ganaId = 'e2e-local-test-${DateTime.now().microsecondsSinceEpoch}';
    final savedId = '$ganaId-knowledge';
    final now = DateTime.now();
    await isar.writeTxn(() async {
      await isar.savedNoteModels.put(SavedNoteModel()
        ..eventId = savedId
        ..sig = 'test'
        ..authorPubkey = 'e2e-knowledge-author'
        ..content = 'The celebration codeword is marmalade.'
        ..type = NoteType.text
        ..eTagRefs = const []
        ..pTagRefs = const []
        ..tTags = const []
        ..created = DateTime(2099, 1, 1)
        ..savedAt = now);
      await isar.ganaModels.put(
        GanaModel()
          ..ganaId = ganaId
          ..name = 'E2E local-model Brahma test Gana'
          ..taskPrompt = 'From the latest KNOWLEDGE note, state the '
              'celebration codeword in one short sentence. Clearly say this '
              'is a test post.'
          ..outputType = GanaOutputType.feed
          // Use the active local model provisioned above.
          ..triggerMode = GanaTriggerMode.oneShot
          ..enabled = true
          ..createdAt = now
          ..updatedAt = now,
      );
    });
    addTearDown(() async {
      await isar.writeTxn(() async {
        await isar.savedNoteModels.filter().eventIdEqualTo(savedId).deleteAll();
      });
    });

    String? publishedEventId;
    final engine = getIt<GanaEngine>();
    await engine.start();

    GanaRunStatus? status;
    // Local generation is much slower than cloud (cold model load +
    // decode) — give it a generous budget.
    final runDeadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(runDeadline)) {
      final run =
          await isar.ganaRunModels.filter().ganaIdEqualTo(ganaId).findFirst();
      if (run != null) {
        status = run.status;
        publishedEventId = run.outputEventId;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await engine.stop();

    expect(status, isNotNull,
        reason: 'no GanaRunModel appeared within 90s — engine never fired');
    expect(status, GanaRunStatus.succeeded,
        reason: 'expected the local run to succeed');
    expect(publishedEventId, isNotNull);

    final eventId = publishedEventId!;
    var acked = false;
    final ackDeadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(ackDeadline)) {
      final queued = await isar.eventQueueModels
          .filter()
          .eventIdEqualTo(eventId)
          .findFirst();
      if (queued != null && queued.sentCount > 0) {
        expect(queued.content.toLowerCase(), contains('marmalade'));
        acked = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    if (!acked) {
      // ignore: avoid_print
      print('FAIL: eventId=$eventId generated + enqueued locally but no '
          'relay OK ack arrived within 30s — check relay connectivity');
      fail('event never reached a relay (no OK ack)');
    }
    // ignore: avoid_print
    print('OK: local Brahma Gana used its knowledge note and published '
        'relay-acked eventId=$eventId');
  }, timeout: const Timeout(Duration(seconds: 150)));
}
