import 'package:uniun/domain/entities/event_queue/queued_event_entity.dart';
import 'package:uniun/domain/entities/note/note_entity.dart';
import 'package:uniun/domain/entities/private_group/encrypted_group_message_entity.dart';
import 'package:uniun/domain/entities/private_group/private_group_entity.dart';
import 'package:uniun/domain/entities/private_group/private_group_join_request_entity.dart';

abstract class E2EEGroupRepository {
  Stream<List<PrivateGroupEntity>> watchGroups();
  Future<List<PrivateGroupEntity>> getGroups();

  Stream<List<NoteEntity>> watchMessages(String groupId);
  Future<List<NoteEntity>> getMessages(String groupId);
  
  Stream<List<PrivateGroupJoinRequestEntity>> watchJoinRequests(String groupId);
  Future<List<PrivateGroupJoinRequestEntity>> getJoinRequests(String groupId);
  
  Future<void> saveGroup(PrivateGroupEntity group);
  Future<void> deleteGroup(String groupId);

  Future<PrivateGroupEntity?> findGroup(String groupId);

  /// Fires whenever the inbound Marmot queue changes.
  Stream<void> watchPendingMessages();
  Future<List<EncryptedGroupMessageEntity>> pendingMessages();
  Future<void> discardPendingMessage(int id);

  /// A Welcome binds [mlsGroupId] to the local group and consumes the queued
  /// event, atomically. Returns false, leaving the event queued, when the
  /// group is not stored locally.
  Future<bool> confirmWelcome({
    required int pendingId,
    required String groupId,
    required String mlsGroupId,
  });

  /// Stores a decrypted group message and consumes its queued event. Unread
  /// only when the message was not stored before.
  Future<void> saveDecryptedMessage({
    required int pendingId,
    required NoteEntity message,
  });

  /// Stores a new group and queues its creation event, atomically.
  Future<void> createGroup({
    required PrivateGroupEntity group,
    required QueuedEventEntity event,
  });

  /// Queues a join request, first storing a stub group (or reactivating the
  /// stored one and filling its relays) so the relay router can find it.
  Future<void> requestJoin({
    required String groupId,
    required List<String> relays,
    required QueuedEventEntity event,
  });

  /// Queues the leave event and removes the local group, atomically.
  Future<void> leaveGroup({
    required String groupId,
    required QueuedEventEntity event,
  });

  /// Stores the sender's own message and queues its encrypted event.
  Future<void> sendMessage({
    required NoteEntity message,
    required QueuedEventEntity event,
  });

  /// The sender of the pending join request carrying [keyPackageB64].
  Future<String?> senderForKeyPackage(String groupId, String keyPackageB64);

  /// Queues [events] and marks the join requests for [keyPackageB64], and
  /// every other pending one from [senderPubkey], as handled, atomically.
  /// With no events it only marks the requests.
  Future<void> approveJoinRequests({
    required String groupId,
    required String keyPackageB64,
    String? senderPubkey,
    List<QueuedEventEntity> events = const [],
  });
}
