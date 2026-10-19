/// An inbound Marmot event (welcome, commit, leave or application message)
/// waiting to be processed.
class EncryptedGroupMessageEntity {
  final int id;
  final String eventId;
  final String groupId;
  final String senderPubkey;
  final int kind;
  final String encryptedPayload;
  final DateTime timestamp;

  const EncryptedGroupMessageEntity({
    required this.id,
    required this.eventId,
    required this.groupId,
    required this.senderPubkey,
    required this.kind,
    required this.encryptedPayload,
    required this.timestamp,
  });
}
