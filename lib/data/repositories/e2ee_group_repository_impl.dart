import 'package:injectable/injectable.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/core/notes/reply_edge.dart';
import 'package:uniun/data/models/encrypted_message_model.dart';
import 'package:uniun/data/models/event_queue_model.dart';
import 'package:uniun/data/models/notes/note_model.dart';
import 'package:uniun/data/models/notes/unread_note_model.dart';
import 'package:uniun/data/models/private_group_model.dart';
import 'package:uniun/data/models/private_group_join_request_model.dart';
import 'package:uniun/data/repositories/note_attachments_enricher.dart';
import 'package:uniun/domain/entities/event_queue/queued_event_entity.dart';
import 'package:uniun/domain/entities/note/note_entity.dart';
import 'package:uniun/domain/entities/private_group/encrypted_group_message_entity.dart';
import 'package:uniun/domain/entities/private_group/private_group_entity.dart';
import 'package:uniun/domain/entities/private_group/private_group_join_request_entity.dart';
import 'package:uniun/domain/repositories/e2ee_group_repository.dart';
import 'package:uniun/domain/repositories/note_relation_repository.dart';
import 'package:uniun/features/mesh/sync/bodies/private_group_body.dart';
import 'package:uniun/features/mesh/sync/mesh_event_codec.dart';
import 'package:uniun/features/mesh/sync/mesh_event_signer.dart';

@LazySingleton(as: E2EEGroupRepository)
class E2EEGroupRepositoryImpl implements E2EEGroupRepository {
  final Isar isar;
  final NoteAttachmentsEnricher _attachments;
  final NoteRelationRepository _relations;
  final MeshEventSigner _signer;

  E2EEGroupRepositoryImpl(
    this.isar,
    this._attachments,
    this._relations,
    this._signer,
  );

  @override
  Future<List<PrivateGroupEntity>> getGroups() async {
    final models = await isar.privateGroupModels.where().findAll();
    return models.map(_mapGroup).toList();
  }

  @override
  Stream<List<PrivateGroupEntity>> watchGroups() {
    return isar.privateGroupModels.where().watch(fireImmediately: true).map((models) {
      return models.map(_mapGroup).toList();
    });
  }

  @override
  Future<List<NoteEntity>> getMessages(String groupId) async {
    final models = await isar.noteModels
        .filter()
        .privateGroupIdEqualTo(groupId)
        .sortByCreated()
        .findAll();
    return _attachments
        .enrichAll([for (final m in models) m.toDomain()]);
  }

  @override
  Stream<List<NoteEntity>> watchMessages(String groupId) {
    return isar.noteModels
        .filter()
        .privateGroupIdEqualTo(groupId)
        .sortByCreated()
        .watch(fireImmediately: true)
        .asyncMap((models) =>
            _attachments.enrichAll([for (final m in models) m.toDomain()]));
  }

  @override
  Future<List<PrivateGroupJoinRequestEntity>> getJoinRequests(String groupId) async {
    final models = await isar.privateGroupJoinRequestModels
        .filter()
        .groupIdEqualTo(groupId)
        .handledEqualTo(false)
        .sortByTimestamp()
        .findAll();
    return models.map(_mapJoinRequest).toList();
  }

  @override
  Stream<List<PrivateGroupJoinRequestEntity>> watchJoinRequests(String groupId) {
    return isar.privateGroupJoinRequestModels
        .filter()
        .groupIdEqualTo(groupId)
        .handledEqualTo(false)
        .sortByTimestamp()
        .watch(fireImmediately: true)
        .map((models) {
      return models.map(_mapJoinRequest).toList();
    });
  }

  @override
  Future<void> saveGroup(PrivateGroupEntity group) async {
    final model = PrivateGroupModel()
      ..id = group.id > 0 ? group.id : Isar.autoIncrement
      ..groupId = group.groupId
      ..mlsGroupId = group.mlsGroupId
      ..relays = group.relays
      ..name = group.name
      ..description = group.description
      ..adminPubkey = group.adminPubkey;

    await isar.writeTxn(() async {
      await isar.privateGroupModels.put(model);
    });
  }

  @override
  Future<void> deleteGroup(String groupId) async {
    await isar.writeTxn(() async {
      await isar.privateGroupModels.where().groupIdEqualTo(groupId).deleteAll();
    });
  }

  @override
  Future<PrivateGroupEntity?> findGroup(String groupId) async {
    final model = await _findModel(groupId);
    return model == null ? null : _mapGroup(model);
  }

  Future<PrivateGroupModel?> _findModel(String groupId) =>
      isar.privateGroupModels.where().groupIdEqualTo(groupId).findFirst();

  @override
  Stream<void> watchPendingMessages() => isar.encryptedMessageModels.watchLazy();

  @override
  Future<List<EncryptedGroupMessageEntity>> pendingMessages() async {
    final rows = await isar.encryptedMessageModels.where().findAll();
    return [
      for (final r in rows)
        EncryptedGroupMessageEntity(
          id: r.id,
          eventId: r.eventId,
          groupId: r.groupId,
          senderPubkey: r.senderPubkey,
          kind: r.kind,
          encryptedPayload: r.encryptedPayload,
          timestamp: r.timestamp,
        ),
    ];
  }

  @override
  Future<void> discardPendingMessage(int id) async {
    await isar.writeTxn(() async {
      await isar.encryptedMessageModels.delete(id);
    });
  }

  @override
  Future<bool> confirmWelcome({
    required int pendingId,
    required String groupId,
    required String mlsGroupId,
  }) async {
    final group = await _findModel(groupId);
    if (group == null) return false;
    // A Welcome confirms real membership on THIS device: bind the MLS group
    // id and re-stamp the mesh event so the confirmed group syncs to the
    // user's other devices.
    group.mlsGroupId = mlsGroupId;
    group.removedAt = null;
    group.signedNostrEvent = await _signer.sign(
      kind: MeshEventKinds.privateGroup,
      dTag: group.groupId,
      content: PrivateGroupBody.forActive(group),
    );
    await isar.writeTxn(() async {
      await isar.privateGroupModels.put(group);
      await isar.encryptedMessageModels.delete(pendingId);
    });
    return true;
  }

  @override
  Future<void> saveDecryptedMessage({
    required int pendingId,
    required NoteEntity message,
  }) async {
    final model = message.toModel();
    await isar.writeTxn(() async {
      // Own messages are already stored from the local send, so a missing row
      // means a genuinely new inbound message and it is marked unread.
      final existing = await isar.noteModels
          .where()
          .eventIdEqualTo(model.eventId)
          .findFirst();
      await isar.noteModels.put(model);
      if (existing == null) {
        await putUnreadRowInTxn(isar, model);
      }
      await _addEdges(model);
      await isar.encryptedMessageModels.delete(pendingId);
    });
  }

  @override
  Future<void> createGroup({
    required PrivateGroupEntity group,
    required QueuedEventEntity event,
  }) async {
    final model = PrivateGroupModel()
      ..groupId = group.groupId
      ..mlsGroupId = group.mlsGroupId
      ..name = group.name
      ..description = group.description
      ..relays = group.relays
      ..adminPubkey = group.adminPubkey;

    // Mesh-sync the created group to the user's other devices.
    model.signedNostrEvent = await _signer.sign(
      kind: MeshEventKinds.privateGroup,
      dTag: group.groupId,
      content: PrivateGroupBody.forActive(model),
    );

    await isar.writeTxn(() async {
      await isar.privateGroupModels.put(model);
      await isar.eventQueueModels.put(_queueRow(event));
    });
  }

  @override
  Future<void> requestJoin({
    required String groupId,
    required List<String> relays,
    required QueuedEventEntity event,
  }) async {
    final existing = await _findModel(groupId);

    // Build or patch the row outside the transaction so the mesh event can be
    // signed (async crypto) before the write opens.
    PrivateGroupModel? toPut;
    if (existing == null) {
      toPut = PrivateGroupModel()
        ..groupId = groupId
        ..mlsGroupId = '' // filled in after Welcome is received
        ..name = groupId // placeholder until metadata synced
        ..description = ''
        ..relays = relays
        ..adminPubkey = '';
    } else if (existing.relays.isEmpty && relays.isNotEmpty) {
      existing.relays = relays;
      toPut = existing;
    }
    if (toPut != null) {
      toPut.removedAt = null;
      toPut.signedNostrEvent = await _signer.sign(
        kind: MeshEventKinds.privateGroup,
        dTag: groupId,
        content: PrivateGroupBody.forActive(toPut),
      );
    }

    await isar.writeTxn(() async {
      if (toPut != null) {
        await isar.privateGroupModels.put(toPut);
      }
      await isar.eventQueueModels.put(_queueRow(event));
    });
  }

  @override
  Future<void> leaveGroup({
    required String groupId,
    required QueuedEventEntity event,
  }) async {
    await isar.writeTxn(() async {
      await isar.eventQueueModels.put(_queueRow(event));
      await isar.privateGroupModels.where().groupIdEqualTo(groupId).deleteAll();
    });
  }

  @override
  Future<void> sendMessage({
    required NoteEntity message,
    required QueuedEventEntity event,
  }) async {
    final model = message.toModel();
    await isar.writeTxn(() async {
      await isar.noteModels.put(model);
      await _addEdges(model);
      await isar.eventQueueModels.put(_queueRow(event));
    });
  }

  @override
  Future<String?> senderForKeyPackage(
    String groupId,
    String keyPackageB64,
  ) async {
    final requests = await isar.privateGroupJoinRequestModels
        .where()
        .groupIdEqualTo(groupId)
        .findAll();
    return requests
        .where((request) =>
            !request.handled && request.keyPackageB64 == keyPackageB64)
        .map((request) => request.senderPubkey)
        .firstOrNull;
  }

  /// The rows are kept rather than deleted: the relay holds the original Kind
  /// 9021 events permanently, so on the next sync the inbound handler re-offers
  /// them. Keeping the rows lets the handler's `eventId` idempotency check skip
  /// the re-insert; the `handled` flag keeps them out of the pending list.
  @override
  Future<void> approveJoinRequests({
    required String groupId,
    required String keyPackageB64,
    String? senderPubkey,
    List<QueuedEventEntity> events = const [],
  }) async {
    await isar.writeTxn(() async {
      if (events.isNotEmpty) {
        await isar.eventQueueModels.putAll([for (final e in events) _queueRow(e)]);
      }
      final requests = await isar.privateGroupJoinRequestModels
          .where()
          .groupIdEqualTo(groupId)
          .findAll();
      final toMark = requests
          .where((request) =>
              !request.handled &&
              (request.keyPackageB64 == keyPackageB64 ||
                  (senderPubkey != null &&
                      request.senderPubkey == senderPubkey)))
          .toList();
      if (toMark.isEmpty) return;
      for (final request in toMark) {
        request.handled = true;
      }
      await isar.privateGroupJoinRequestModels.putAll(toMark);
    });
  }

  /// Reference edges for [model] through the shared edge table. `eTagRefs`
  /// only, matching the decrypt path: a group message has no NIP-10 markers.
  Future<void> _addEdges(NoteModel model) => _relations.addEdgesInTxn(
        parents: replyEdgeParentIds(
          replyToEventId: null,
          rootEventId: null,
          eTagRefs: model.eTagRefs,
        ),
        childId: model.eventId,
      );

  EventQueueModel _queueRow(QueuedEventEntity e) => EventQueueModel()
    ..eventId = e.eventId
    ..kind = e.kind
    ..content = e.content
    ..authorPubkey = e.authorPubkey
    ..sig = e.sig
    ..eTagRefs = []
    ..pTagRefs = []
    ..tTags = []
    ..hTag = e.hTag
    ..sentCount = 0
    ..created = e.created
    ..enqueuedAt = DateTime.now();

  PrivateGroupEntity _mapGroup(PrivateGroupModel model) {
    return PrivateGroupEntity(
      id: model.id,
      groupId: model.groupId,
      mlsGroupId: model.mlsGroupId,
      relays: model.relays,
      name: model.name,
      description: model.description,
      adminPubkey: model.adminPubkey,
    );
  }

  PrivateGroupJoinRequestEntity _mapJoinRequest(PrivateGroupJoinRequestModel model) {
    return PrivateGroupJoinRequestEntity(
      id: model.id,
      eventId: model.eventId,
      groupId: model.groupId,
      senderPubkey: model.senderPubkey,
      keyPackageB64: model.keyPackageB64,
      timestamp: model.timestamp,
    );
  }
}
