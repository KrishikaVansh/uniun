// Full end-to-end verification of Gana's UNIUN Cloud pin, run against the
// REAL app: real DI (`configureDependencies`), the real on-device Isar, the
// real `GanaEngine`, the real `GatewayBootstrap` sync isolate, and a real
// call to the live UNIUN Cloud gateway.
//
// Preconditions are self-provisioned, idempotently: if the device already
// has an active identity and/or is already UNIUN-Cloud-connected, both
// steps are skipped and the existing state is reused untouched; only
// whichever is actually missing gets created. Provisioning a fresh identity
// never flips the device's globally active LLM backend — Gana's cloud pin
// is a per-agent override, independent of that global setting.
//
// Main flow only: seed one standalone, one-shot, cloud-pinned Gana on a
// free-tier model directly into the real Isar → start the real `GanaEngine`
// via `getIt` → wait for it to fire (standalone one-shot Ganas fire
// immediately on enable) → start the real `GatewayBootstrap` (the Gateway
// isolate is normally only spawned by `HomePage`, which this test never
// mounts — without this, the publish only ever reaches local Isar and is
// never actually sent to a relay) → wait for a real relay `OK` ack
// (`EventQueueModel.sentCount > 0`) before calling it published.
//
// Side effect the test author (and whoever runs this) must accept: on
// success this publishes ONE real Kind-1 note to the connected identity's
// real feed via the real relay. UNIUN has no delete (Feed Freedom, NIP-09
// permanently excluded) — the published event is permanent on the relay
// regardless. By request, this test does NOT clean up after itself — the
// Gana definition, its run log, and the note all stay in local Isar too,
// so the test post is actually visible in the app afterward instead of
// vanishing the moment the test ends. Run this against a disposable/test
// identity, not a primary account.
//
//   flutter test integration_test/gana_cloud_engine_e2e_test.dart -d <device-id>

import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart' show GemmaEmbeddingTokenizers;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/common/locator.dart';
import 'package:uniun/core/enum/gana_output_type.dart';
import 'package:uniun/core/enum/gana_run_status.dart';
import 'package:uniun/core/enum/gana_trigger_mode.dart';
import 'package:uniun/data/datasources/cloud/uniun_gateway_client.dart';
import 'package:uniun/data/models/event_queue_model.dart';
import 'package:uniun/data/models/gana_model.dart';
import 'package:uniun/data/models/gana_run_model.dart';
import 'package:uniun/domain/entities/llm/llm_backend_type.dart';
import 'package:uniun/domain/repositories/user_repository.dart';
import 'package:uniun/domain/usecases/llm_usecases.dart';
import 'package:uniun/features/shiv/gana/engine/gana_engine.dart';
import 'package:uniun/gateway/gateway.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('a cloud-pinned standalone Gana runs end-to-end and reaches a real relay',
      () async {
    await configureDependencies();
    final isar = getIt<Isar>();

    // `configureDependencies()` never touches flutter_edge_ai —
    // `EmbedAndStoreNoteUseCase` (fired after every publish, cloud included,
    // to index the note for Shiv's vector search) needs it initialized or
    // it fails with "FlutterEdgeAi not initialized!" on the embed step.
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
      embeddingBackends: const [LiteRtEmbeddingBackend()],
      embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
    );

    var keys = await getIt<UserRepository>().getActiveKeysHex();
    if (keys == null) {
      final generated = await getIt<UserRepository>().generateKey();
      final ok = generated.fold((f) {
        // ignore: avoid_print
        print('SKIP: no active identity and generating one failed: $f');
        return false;
      }, (_) => true);
      if (!ok) return;
      keys = await getIt<UserRepository>().getActiveKeysHex();
      // ignore: avoid_print
      print('provisioned a fresh identity for this run: '
          'pubkey=${keys?.pubkeyHex}');
    }

    var connected = await getIt<IsUniunCloudConnectedUseCase>().call();
    if (!connected) {
      final result = await getIt<ConnectUniunCloudUseCase>().call();
      final ok = result.fold((f) {
        // ignore: avoid_print
        print('SKIP: UNIUN Cloud not connected and connecting failed: $f');
        return false;
      }, (_) => true);
      if (!ok) return;
      connected = await getIt<IsUniunCloudConnectedUseCase>().call();
      // ignore: avoid_print
      print('connected UNIUN Cloud for this run');
    }

    final free = (await UniunGatewayClient().listModels())
        .where((m) => !m.isPaid)
        .toList();
    if (free.isEmpty) {
      // ignore: avoid_print
      print('SKIP: no free-tier model on the public catalog to test against');
      return;
    }

    // The Gateway sync isolate — the only thing that actually talks to a
    // relay over the wire — is normally spawned by `HomePage`. This test
    // never mounts a widget tree, so start it explicitly; without this the
    // publish below only ever reaches local Isar.
    await GatewayBootstrap.start();

    final ganaId = 'e2e-test-${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now();
    await isar.writeTxn(() async {
      await isar.ganaModels.put(
        GanaModel()
          ..ganaId = ganaId
          ..name = 'E2E test Gana (auto-deleted)'
          ..taskPrompt = 'Write one short, friendly sentence (max 20 words) '
              'announcing that this note was posted by a Gana AI agent '
              'running on a UNIUN Cloud model, as a test of that feature. '
              'Clearly say it is a test post.'
          ..outputType = GanaOutputType.feed
          ..desiredBackend = LlmBackendType.uniunCloud
          ..desiredModelId = free.first.id
          ..triggerMode = GanaTriggerMode.oneShot
          ..enabled = true
          ..createdAt = now
          ..updatedAt = now,
      );
    });

    String? publishedEventId;
    final engine = getIt<GanaEngine>();
    await engine.start();

    GanaRunStatus? status;
    final runDeadline = DateTime.now().add(const Duration(seconds: 45));
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
        reason: 'no GanaRunModel appeared within 45s — engine never fired');
    expect(status, GanaRunStatus.succeeded,
        reason: 'expected the cloud-pinned run to succeed');
    expect(publishedEventId, isNotNull);

    // Local-only success so far — wait for the Gateway isolate to
    // actually connect and get a relay `OK` ack before calling this a
    // real publish.
    final eventId = publishedEventId!;
    var acked = false;
    final ackDeadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(ackDeadline)) {
      final queued = await isar.eventQueueModels
          .filter()
          .eventIdEqualTo(eventId)
          .findFirst();
      if (queued != null && queued.sentCount > 0) {
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
    print('OK: cloud Gana published + relay-acked eventId=$eventId '
        'via model=${free.first.id}');
  }, timeout: const Timeout(Duration(seconds: 100)));
}
