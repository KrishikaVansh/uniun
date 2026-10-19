import 'package:dartz/dartz.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/domain/entities/dm/encrypted_dm_entity.dart';
import 'package:uniun/domain/entities/note/note_entity.dart';

/// Storage behind `Nip17EncryptionService`: the inbound gift-wrap queue and
/// the DM note writes that follow a decrypt or a send.
abstract class Nip17Repository {
  /// Fires whenever the gift-wrap queue changes.
  Stream<void> watchPendingGiftWraps();

  Future<Either<Failure, List<EncryptedDmEntity>>> pendingGiftWraps();

  Future<Either<Failure, Unit>> discardGiftWrap(int id);

  /// Stores a decrypted DM and consumes its gift wrap in one transaction.
  ///
  /// Makes sure a conversation with [otherPubkey] exists first and stamps
  /// its id on the note. A message already stored only consumes the wrap.
  /// Messages not written by [ownPubkey] are marked unread.
  Future<Either<Failure, Unit>> saveInbound({
    required int giftWrapId,
    required String otherPubkey,
    required NoteEntity message,
    String? ownPubkey,
  });

  /// Stores the sender's own copy of an outgoing DM and its reply edges.
  Future<Either<Failure, Unit>> saveOutgoing(NoteEntity message);
}
