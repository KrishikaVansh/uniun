/// An inbound NIP-17 gift wrap (Kind 1059) waiting to be decrypted.
class EncryptedDmEntity {
  final int id;
  final String eventId;
  final String authorPubkey;
  final String content;

  const EncryptedDmEntity({
    required this.id,
    required this.eventId,
    required this.authorPubkey,
    required this.content,
  });
}
