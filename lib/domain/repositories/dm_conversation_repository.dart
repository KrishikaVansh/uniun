import 'package:dartz/dartz.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/domain/entities/dm/dm_conversation_entity.dart';

abstract class DmConversationRepository {
  Future<Either<Failure, List<DmConversationEntity>>> getConversations();

  Future<Either<Failure, DmConversationEntity>> getConversationByOtherPubkey(
    String otherPubkey,
  );

  /// Idempotent: if conversation already exists, no change is applied.
  Future<Either<Failure, DmConversationEntity>> saveConversation(
    DmConversationEntity entity,
  );

  /// The conversation with [otherPubkey], created or reactivated when it is
  /// missing or removed. Used when a message arrives from a first-time peer;
  /// the pubkey is taken as given and signing is best-effort.
  Future<Either<Failure, DmConversationEntity>> ensureActive(
    String otherPubkey,
  );

  Future<Either<Failure, Unit>> deleteConversation(String otherPubkey);
}
