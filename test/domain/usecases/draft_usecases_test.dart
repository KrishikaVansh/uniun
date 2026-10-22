import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/domain/entities/draft/draft_entity.dart';
import 'package:uniun/domain/repositories/draft_repository.dart';
import 'package:uniun/domain/usecases/draft_usecases.dart';

class _MockDraftRepository extends Mock implements DraftRepository {}

DraftEntity _aDraft({String draftId = 'draft-1'}) => DraftEntity(
      draftId: draftId,
      content: 'a draft',
      eTagRefs: const [],
      pTagRefs: const [],
      tTags: const [],
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

void main() {
  late _MockDraftRepository repo;

  setUpAll(() {
    registerFallbackValue(_aDraft());
  });

  setUp(() {
    repo = _MockDraftRepository();
  });

  test('SaveDraftUseCase delegates to saveDraft', () async {
    final draft = _aDraft();
    when(() => repo.saveDraft(draft)).thenAnswer((_) async => Right(draft));

    final result = await SaveDraftUseCase(repo).call(draft);

    expect(result, Right(draft));
  });

  test('GetDraftsUseCase delegates to getDrafts', () async {
    when(() => repo.getDrafts()).thenAnswer((_) async => Right([_aDraft()]));

    final result = await GetDraftsUseCase(repo).call();

    expect(result.getOrElse(() => []), hasLength(1));
  });

  test('GetDraftByIdUseCase delegates to getDraftById', () async {
    when(() => repo.getDraftById('draft-1')).thenAnswer((_) async => Right(_aDraft()));

    await GetDraftByIdUseCase(repo).call('draft-1');

    verify(() => repo.getDraftById('draft-1')).called(1);
  });

  test('GetDraftRepliesUseCase delegates to getDraftsReferencing', () async {
    when(() => repo.getDraftsReferencing('draft-1'))
        .thenAnswer((_) async => Right([_aDraft()]));

    final result = await GetDraftRepliesUseCase(repo).call('draft-1');

    expect(result.getOrElse(() => []), hasLength(1));
    verify(() => repo.getDraftsReferencing('draft-1')).called(1);
  });

  test('DeleteDraftUseCase delegates to deleteDraft', () async {
    when(() => repo.deleteDraft('draft-1')).thenAnswer((_) async => const Right(unit));

    final result = await DeleteDraftUseCase(repo).call('draft-1');

    expect(result, const Right<Failure, Unit>(unit));
  });

  test('MarkDraftPublishedUseCase forwards draftId + eventId', () async {
    when(() => repo.markPublished(draftId: 'draft-1', eventId: 'evt-1'))
        .thenAnswer((_) async => const Right(unit));

    await MarkDraftPublishedUseCase(repo)
        .call(const MarkDraftPublishedInput(draftId: 'draft-1', eventId: 'evt-1'));

    verify(() => repo.markPublished(draftId: 'draft-1', eventId: 'evt-1')).called(1);
  });
}
