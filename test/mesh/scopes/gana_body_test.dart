// Body-level roundtrip for Kind 30520 (Gana definition, plan §5).

import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/core/enum/gana_input_type.dart';
import 'package:uniun/core/enum/gana_output_type.dart';
import 'package:uniun/core/enum/gana_trigger_mode.dart';
import 'package:uniun/data/models/gana_model.dart';
import 'package:uniun/domain/entities/llm/llm_backend_type.dart';
import 'package:uniun/features/mesh/sync/bodies/gana_body.dart';
import 'package:uniun/features/mesh/sync/mesh_event_codec.dart';

void main() {
  GanaModel makeRow() => GanaModel()
    ..ganaId = 'gana-1'
    ..name = 'Daily digest'
    ..manasIds = const ['manas-a', 'manas-b']
    ..taskPrompt = 'Summarise the last 24h'
    ..inputType = GanaInputType.followedNote
    ..inputRefId = 'ffee00'
    ..outputType = GanaOutputType.feed
    ..outputGroupId = null
    ..outputPrivateGroupId = null
    ..outputDmConversationId = null
    ..desiredModelId = 'qwen3-0.6b'
    ..desiredBackend = LlmBackendType.localGemma
    ..triggerReactive = true
    ..triggerIntervalMinutes = 60
    ..triggerMode = GanaTriggerMode.recurring
    ..maxOutputs = 10
    ..enabled = true
    ..lastProcessedEventId = 'runtime-cursor-should-not-serialize'
    ..lastProcessedCreated = DateTime.fromMillisecondsSinceEpoch(1720999999000)
    ..lastRunAt = DateTime.fromMillisecondsSinceEpoch(1720999999000)
    ..createdAt = DateTime.fromMillisecondsSinceEpoch(1720000000000)
    ..updatedAt = DateTime.fromMillisecondsSinceEpoch(1720001000000);

  test('forActive encodes every definition field', () {
    final body = GanaBody.forActive(makeRow());
    expect(body['state'], MeshRecordState.active.wire);
    expect(body['name'], 'Daily digest');
    expect(body['manasIds'], ['manas-a', 'manas-b']);
    expect(body['taskPrompt'], 'Summarise the last 24h');
    expect(body['inputType'], 'followedNote');
    expect(body['inputRefId'], 'ffee00');
    expect(body['outputType'], 'feed');
    expect(body['desiredModelId'], 'qwen3-0.6b');
    expect(body['desiredBackend'], 'localGemma');
    expect(body['triggerReactive'], true);
    expect(body['triggerIntervalMinutes'], 60);
    expect(body['triggerMode'], 'recurring');
    expect(body['maxOutputs'], 10);
    expect(body['enabled'], true);
    expect(body['createdAt'], 1720000000000);
    expect(body['updatedAt'], 1720001000000);
  });

  test('the no-knowledge choice round-trips through the wire body', () {
    final body = GanaBody.forActive(makeRow()..noKnowledge = true);

    expect(body['noKnowledge'], isTrue);
    expect(GanaBody.applyBody(body, ganaId: 'gana-1').noKnowledge, isTrue);
  });

  test('a body from an older device (no noKnowledge key) means false', () {
    final body = GanaBody.forActive(makeRow())..remove('noKnowledge');

    expect(GanaBody.applyBody(body, ganaId: 'gana-1').noKnowledge, isFalse);
  });

  test('a malformed noKnowledge value falls back to false', () {
    final body = GanaBody.forActive(makeRow())..['noKnowledge'] = 'yes';

    expect(GanaBody.applyBody(body, ganaId: 'gana-1').noKnowledge, isFalse);
  });

  test('forActive does NOT leak runtime cursor state onto the wire', () {
    final body = GanaBody.forActive(makeRow());
    // Per-device cursors are intentionally excluded from the mesh wire.
    expect(body.containsKey('lastProcessedEventId'), isFalse);
    expect(body.containsKey('lastProcessedCreated'), isFalse);
    expect(body.containsKey('lastRunAt'), isFalse);
  });

  test('forRemoved flips state but keeps definition fields', () {
    final body = GanaBody.forRemoved(makeRow());
    expect(body['state'], MeshRecordState.removed.wire);
    expect(body['name'], 'Daily digest');
    expect(body['enabled'], true);
  });

  test('applyBody rehydrates a fresh row', () {
    final body = GanaBody.forActive(makeRow());
    final row = GanaBody.applyBody(body, ganaId: 'gana-1');
    expect(row.ganaId, 'gana-1');
    expect(row.name, 'Daily digest');
    expect(row.manasIds, ['manas-a', 'manas-b']);
    expect(row.taskPrompt, 'Summarise the last 24h');
    expect(row.inputType, GanaInputType.followedNote);
    expect(row.inputRefId, 'ffee00');
    expect(row.outputType, GanaOutputType.feed);
    expect(row.desiredModelId, 'qwen3-0.6b');
    expect(row.desiredBackend, LlmBackendType.localGemma);
    expect(row.triggerReactive, isTrue);
    expect(row.triggerIntervalMinutes, 60);
    expect(row.triggerMode, GanaTriggerMode.recurring);
    expect(row.maxOutputs, 10);
    expect(row.enabled, isTrue);
    expect(row.createdAt.millisecondsSinceEpoch, 1720000000000);
    expect(row.updatedAt.millisecondsSinceEpoch, 1720001000000);
  });

  test('applyBody merges onto an existing row (preserves Isar id)', () {
    final existing = makeRow()..id = 42;
    final body = GanaBody.forActive(
      makeRow()
        ..name = 'Renamed'
        ..updatedAt = DateTime.fromMillisecondsSinceEpoch(1720002000000),
    );
    final row = GanaBody.applyBody(body, ganaId: 'gana-1', existing: existing);
    expect(row.id, 42);
    expect(row.name, 'Renamed');
    expect(row.updatedAt.millisecondsSinceEpoch, 1720002000000);
  });

  test('applyBody preserves runtime cursor state on the existing row', () {
    // The wire body never carries cursor state, so applying a remote body to
    // a row with local cursor progress must not clobber it.
    final existing = makeRow()
      ..id = 7
      ..lastProcessedEventId = 'local-abc123'
      ..lastProcessedCreated = DateTime.fromMillisecondsSinceEpoch(9990000000)
      ..lastRunAt = DateTime.fromMillisecondsSinceEpoch(9990000000);
    final body = GanaBody.forActive(makeRow());
    final row = GanaBody.applyBody(body, ganaId: 'gana-1', existing: existing);
    expect(row.lastProcessedEventId, 'local-abc123');
    expect(row.lastProcessedCreated!.millisecondsSinceEpoch, 9990000000);
    expect(row.lastRunAt!.millisecondsSinceEpoch, 9990000000);
  });

  test('applyBody tolerates a missing name (falls back to empty)', () {
    final row = GanaBody.applyBody(
      <String, dynamic>{
        'state': 'active',
        'outputType': 'feed',
        'triggerMode': 'recurring',
        'createdAt': 1720000000000,
        'updatedAt': 1720000000000,
      },
      ganaId: 'gana-2',
    );
    expect(row.name, '');
    expect(row.taskPrompt, '');
    expect(row.manasIds, isEmpty);
    expect(row.enabled, isFalse);
  });

  test('applyBody defaults unknown outputType and triggerMode enums safely',
      () {
    // Forward-compat: a peer running a newer schema may send a field value we
    // don't recognise. We fall back rather than crashing.
    final row = GanaBody.applyBody(
      <String, dynamic>{
        'state': 'active',
        'name': 'x',
        'outputType': 'some-future-mode',
        'triggerMode': 'some-future-trigger',
        'createdAt': 1,
        'updatedAt': 1,
      },
      ganaId: 'gana-x',
    );
    expect(row.outputType, GanaOutputType.values.first);
    expect(row.triggerMode, GanaTriggerMode.recurring);
  });

  test('applyBody handles nullable numeric fields', () {
    final row = GanaBody.applyBody(
      <String, dynamic>{
        'state': 'active',
        'outputType': 'feed',
        'triggerMode': 'recurring',
        'createdAt': 1,
        'updatedAt': 1,
        'triggerIntervalMinutes': null,
        'maxOutputs': null,
        'outputDmConversationId': null,
      },
      ganaId: 'gana-null',
    );
    expect(row.triggerIntervalMinutes, isNull);
    expect(row.maxOutputs, isNull);
    expect(row.outputDmConversationId, isNull);
  });

  // ── Edge cases: desiredBackend (cloud pin) ────────────────────────────

  test('a cloud-pinned Gana round-trips desiredBackend=uniunCloud', () {
    final body = GanaBody.forActive(
      makeRow()
        ..desiredModelId = 'claude-cloud-mini'
        ..desiredBackend = LlmBackendType.uniunCloud,
    );
    expect(body['desiredBackend'], 'uniunCloud');
    final row = GanaBody.applyBody(body, ganaId: 'gana-1');
    expect(row.desiredModelId, 'claude-cloud-mini');
    expect(row.desiredBackend, LlmBackendType.uniunCloud);
  });

  test('a legacy row with no desiredBackend serializes/deserializes to null',
      () {
    final body = GanaBody.forActive(makeRow()..desiredBackend = null);
    expect(body['desiredBackend'], isNull);
    final row = GanaBody.applyBody(body, ganaId: 'gana-1');
    expect(row.desiredBackend, isNull);
  });

  test('applyBody drops an unrecognized desiredBackend wire value to null',
      () {
    final row = GanaBody.applyBody(
      <String, dynamic>{
        'state': 'active',
        'outputType': 'feed',
        'triggerMode': 'recurring',
        'createdAt': 1,
        'updatedAt': 1,
        'desiredBackend': 'openRouter', // pre-UNIUN backend, no longer valid
      },
      ganaId: 'gana-legacy',
    );
    expect(row.desiredBackend, isNull);
  });
}
