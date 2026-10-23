import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/core/usecases/usecase.dart';
import 'package:uniun/domain/entities/draft/draft_entity.dart';
import 'package:uniun/domain/repositories/draft_repository.dart';

/// Save a draft (create or update).
@lazySingleton
class SaveDraftUseCase extends UseCase<Either<Failure, DraftEntity>, DraftEntity> {
  final DraftRepository repository;

  SaveDraftUseCase(this.repository);

  @override
  Future<Either<Failure, DraftEntity>> call(DraftEntity input, {bool cached = false}) {
    return repository.saveDraft(input);
  }
}

/// Get all drafts, ordered by most recent first.
@lazySingleton
class GetDraftsUseCase extends NoParamsUseCase<Either<Failure, List<DraftEntity>>> {
  final DraftRepository repository;

  GetDraftsUseCase(this.repository);

  @override
  Future<Either<Failure, List<DraftEntity>>> call() {
    return repository.getDrafts();
  }
}

/// Get a single draft by ID.
@lazySingleton
class GetDraftByIdUseCase extends UseCase<Either<Failure, DraftEntity>, String> {
  final DraftRepository repository;

  GetDraftByIdUseCase(this.repository);

  @override
  Future<Either<Failure, DraftEntity>> call(String draftId, {bool cached = false}) {
    return repository.getDraftById(draftId);
  }
}

/// Drafts written as replies to the draft with the given id, oldest first.
@lazySingleton
class GetDraftRepliesUseCase
    extends UseCase<Either<Failure, List<DraftEntity>>, String> {
  final DraftRepository repository;

  GetDraftRepliesUseCase(this.repository);

  @override
  Future<Either<Failure, List<DraftEntity>>> call(
    String draftId, {
    bool cached = false,
  }) {
    return repository.getDraftsReferencing(draftId);
  }
}

/// Delete a draft.
@lazySingleton
class DeleteDraftUseCase extends UseCase<Either<Failure, Unit>, String> {
  final DraftRepository repository;

  DeleteDraftUseCase(this.repository);

  @override
  Future<Either<Failure, Unit>> call(String draftId, {bool cached = false}) {
    return repository.deleteDraft(draftId);
  }
}

class MarkDraftPublishedInput {
  const MarkDraftPublishedInput({
    required this.draftId,
    required this.eventId,
  });
  final String draftId;
  final String eventId;
}

/// Tombstones a draft after publish — stamps `publishedAsEventId`, republishes
/// the NIP-37 wrap with a `published-as` pointer so other devices can map the
/// UUID to the new event id and rewrite their dependent drafts.
@lazySingleton
class MarkDraftPublishedUseCase
    extends UseCase<Either<Failure, Unit>, MarkDraftPublishedInput> {
  final DraftRepository repository;

  MarkDraftPublishedUseCase(this.repository);

  @override
  Future<Either<Failure, Unit>> call(
    MarkDraftPublishedInput input, {
    bool cached = false,
  }) {
    return repository.markPublished(
      draftId: input.draftId,
      eventId: input.eventId,
    );
  }
}

