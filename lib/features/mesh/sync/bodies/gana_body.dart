import 'package:uniun/core/enum/gana_input_type.dart';
import 'package:uniun/core/enum/gana_output_type.dart';
import 'package:uniun/core/enum/gana_trigger_mode.dart';
import 'package:uniun/data/models/gana_model.dart';
import 'package:uniun/domain/entities/llm/llm_backend_type.dart';

import '../mesh_event_codec.dart';

/// Cleartext body shape for the Kind-30520 Gana definition event (plan §5).
///
/// The `d` tag is the Gana's `ganaId`, so create / rename / enable-toggle /
/// delete all address the same addressable slot. LWW on `created_at` collapses
/// edit history to a single winning definition per device.
///
/// Per-device runtime cursor state (`lastProcessedEventId`,
/// `lastProcessedCreated`, `lastRunAt`) is intentionally NOT part of the body —
/// each device's engine loop maintains its own cursor and syncing them would
/// cause devices to skip inputs that another device has already consumed.
class GanaBody {
  const GanaBody._();

  static Map<String, dynamic> forActive(GanaModel g) => _base(
        g,
        state: MeshRecordState.active,
      );

  static Map<String, dynamic> forRemoved(GanaModel g) => _base(
        g,
        state: MeshRecordState.removed,
      );

  static Map<String, dynamic> _base(
    GanaModel g, {
    required MeshRecordState state,
  }) {
    return <String, dynamic>{
      'state': state.wire,
      'name': g.name,
      'manasIds': List<String>.from(g.manasIds),
      'noKnowledge': g.noKnowledge,
      'taskPrompt': g.taskPrompt,
      'inputType': g.inputType?.name,
      'inputRefId': g.inputRefId,
      'outputType': g.outputType.name,
      'outputGroupId': g.outputGroupId,
      'outputPrivateGroupId': g.outputPrivateGroupId,
      'outputDmConversationId': g.outputDmConversationId,
      'desiredModelId': g.desiredModelId,
      'desiredBackend': g.desiredBackend?.name,
      'triggerReactive': g.triggerReactive,
      'triggerIntervalMinutes': g.triggerIntervalMinutes,
      'triggerMode': g.triggerMode.name,
      'maxOutputs': g.maxOutputs,
      'enabled': g.enabled,
      'createdAt': g.createdAt.millisecondsSinceEpoch,
      'updatedAt': g.updatedAt.millisecondsSinceEpoch,
    };
  }

  /// Applies a decoded body onto a [GanaModel] (creates one if [existing]
  /// is null). Caller sets `signedNostrEvent` + `removedAt` per the winning
  /// event's state.
  ///
  /// Preserves the row's runtime cursor (`lastProcessedEventId`,
  /// `lastProcessedCreated`, `lastRunAt`) — those are per-device local state
  /// and never round-trip through the wire.
  static GanaModel applyBody(
    Map<String, dynamic> body, {
    required String ganaId,
    GanaModel? existing,
  }) {
    final row = existing ?? GanaModel();
    row.ganaId = ganaId;
    row.name = (body['name'] as String?) ?? '';
    row.manasIds = _asStringList(body['manasIds']);
    row.noKnowledge = body['noKnowledge'] == true;
    row.taskPrompt = (body['taskPrompt'] as String?) ?? '';
    row.inputType = _parseInputType(body['inputType']);
    row.inputRefId = body['inputRefId'] as String?;
    row.outputType = _parseOutputType(body['outputType']);
    row.outputGroupId = body['outputGroupId'] as String?;
    row.outputPrivateGroupId = body['outputPrivateGroupId'] as String?;
    row.outputDmConversationId = _asIntOrNull(body['outputDmConversationId']);
    row.desiredModelId = body['desiredModelId'] as String?;
    row.desiredBackend = LlmBackendType.fromName(body['desiredBackend'] as String?);
    row.triggerReactive = (body['triggerReactive'] as bool?) ?? false;
    row.triggerIntervalMinutes = _asIntOrNull(body['triggerIntervalMinutes']);
    row.triggerMode = _parseTriggerMode(body['triggerMode']);
    row.maxOutputs = _asIntOrNull(body['maxOutputs']);
    row.enabled = (body['enabled'] as bool?) ?? false;
    row.createdAt = DateTime.fromMillisecondsSinceEpoch(
      _asInt(body['createdAt']),
    );
    row.updatedAt = DateTime.fromMillisecondsSinceEpoch(
      _asInt(body['updatedAt']),
    );
    return row;
  }

  static int _asInt(Object? v) => (v is num) ? v.toInt() : 0;

  static int? _asIntOrNull(Object? v) => (v is num) ? v.toInt() : null;

  static List<String> _asStringList(Object? v) {
    if (v is List) {
      return v.whereType<String>().toList(growable: false);
    }
    return const <String>[];
  }

  static GanaInputType? _parseInputType(Object? v) {
    if (v is! String) return null;
    for (final t in GanaInputType.values) {
      if (t.name == v) return t;
    }
    return null;
  }

  static GanaOutputType _parseOutputType(Object? v) {
    if (v is String) {
      for (final t in GanaOutputType.values) {
        if (t.name == v) return t;
      }
    }
    // Fallback keeps forward-compat if a peer sends an unknown enum value.
    return GanaOutputType.values.first;
  }

  static GanaTriggerMode _parseTriggerMode(Object? v) {
    if (v is String) {
      for (final t in GanaTriggerMode.values) {
        if (t.name == v) return t;
      }
    }
    return GanaTriggerMode.recurring;
  }
}
