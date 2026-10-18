/// A fully signed event handed to the outbound queue, with the one tag the
/// queue serializer needs to rebuild it: the NIP-29 `h` group id.
class QueuedEventEntity {
  final String eventId;
  final int kind;
  final String content;
  final String authorPubkey;
  final String sig;
  final DateTime created;
  final String? hTag;

  const QueuedEventEntity({
    required this.eventId,
    required this.kind,
    required this.content,
    required this.authorPubkey,
    required this.sig,
    required this.created,
    this.hTag,
  });
}
