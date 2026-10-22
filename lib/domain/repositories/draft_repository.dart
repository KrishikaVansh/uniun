import 'package:dartz/dartz.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/domain/entities/draft/draft_entity.dart';

abstract class DraftRepository {
  Future<Either<Failure, DraftEntity>> saveDraft(DraftEntity draft);
  Future<Either<Failure, List<DraftEntity>>> getDrafts();
  Future<Either<Failure, DraftEntity>> getDraftById(String draftId);
  Future<Either<Failure, Unit>> deleteDraft(String draftId);

  /// Unpublished drafts that reference [draftId] in their `draftRefIds`, i.e.
  /// the drafts written as replies to it, oldest first.
  Future<Either<Failure, List<DraftEntity>>> getDraftsReferencing(
    String draftId,
  );

  /// Marks the draft as published — sets `publishedAsEventId`, keeps the row
  /// as a brief tombstone, and republishes a NIP-37 wrap that carries
  /// `["published-as", eventId]` so other devices learn the UUID→event-id
  /// mapping. Used by the publish flow + the publish-chain reconciler.
  Future<Either<Failure, Unit>> markPublished({
    required String draftId,
    required String eventId,
  });

  /// Sweep step run on every inbound Kind-31234 wrap that carries a
  /// `published-as` tag: rewrites any draft on this device whose
  /// `draftRefIds` contains [draftUuid], removing the UUID and adding
  /// [eventId] to its `eTagRefs` instead. Idempotent.
  Future<Either<Failure, Unit>> rewriteDraftRefs({
    required String draftUuid,
    required String eventId,
  });

  /// Cleanup hook: delete every tombstone (`publishedAsEventId` non-null)
  /// older than the retention window. Called by [CleanupManager].
  Future<Either<Failure, int>> purgePublishedTombstonesOlderThan(
    Duration retention,
  );
}
