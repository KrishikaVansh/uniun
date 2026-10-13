import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/domain/entities/storage/storage_stats.dart';
import 'package:uniun/domain/usecases/app_settings_usecases.dart';
import 'package:uniun/domain/usecases/storage_usecases.dart';
import 'package:uniun/domain/usecases/user_usecases.dart';
import 'package:uniun/features/settings/cubit/storage_cubit.dart';

import '../../../_helpers/fixtures.dart';

class _MockStats extends Mock implements GetStorageStatsUseCase {}

class _MockDeleteNotes extends Mock implements DeleteFeedNotesUseCase {}

class _MockDeleteChats extends Mock implements DeleteAllChatHistoryUseCase {}

class _MockUser extends Mock implements GetActiveUserUseCase {}

class _MockGetAuto extends Mock implements GetAutoDeleteOldNotesDaysUseCase {}

class _MockSetAuto extends Mock implements SetAutoDeleteOldNotesDaysUseCase {}

class _MockGetSync extends Mock implements GetRecentSyncWindowDaysUseCase {}

class _MockSetSync extends Mock implements SetRecentSyncWindowDaysUseCase {}

const _stats = StorageStats(
  dbSizeBytes: 10,
  modelSizeBytes: 20,
  chatHistorySizeBytes: 30,
  mediaSizeBytes: 40,
  otherSizeBytes: 50,
  totalNoteCount: 7,
  deletableFeedNoteCount: 5,
  conversationCount: 2,
  freeDiskBytes: 999,
);

/// Covers: StorageCubit loading the stats, the no-identity and failure paths,
/// the two retention settings, and deleting feed notes / chat history.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockStats stats;
  late _MockDeleteNotes deleteNotes;
  late _MockDeleteChats deleteChats;
  late _MockUser user;
  late _MockGetAuto getAuto;
  late _MockSetAuto setAuto;
  late _MockGetSync getSync;
  late _MockSetSync setSync;

  StorageCubit build() => StorageCubit(
    stats,
    deleteNotes,
    deleteChats,
    user,
    getAuto,
    setAuto,
    getSync,
    setSync,
  );

  setUp(() {
    stats = _MockStats();
    deleteNotes = _MockDeleteNotes();
    deleteChats = _MockDeleteChats();
    user = _MockUser();
    getAuto = _MockGetAuto();
    setAuto = _MockSetAuto();
    getSync = _MockGetSync();
    setSync = _MockSetSync();
    when(() => user.call()).thenAnswer((_) async => Right(aUserKey()));
    when(() => stats.call(any())).thenAnswer((_) async => const Right(_stats));
    when(() => getAuto.call()).thenAnswer((_) async => const Right(30));
    when(() => getSync.call()).thenAnswer((_) async => const Right(14));
    when(() => setAuto.call(any())).thenAnswer((_) async => const Right(unit));
    when(() => setSync.call(any())).thenAnswer((_) async => const Right(unit));
    when(() => deleteNotes.call(any())).thenAnswer((_) async => const Right(5));
    when(() => deleteChats.call()).thenAnswer((_) async => const Right(unit));
  });

  test('loadStats fills the numbers and the retention choices', () async {
    final c = build();

    await c.loadStats();

    expect(c.state.isLoading, isFalse);
    expect(c.state.dbSizeBytes, 10);
    expect(c.state.modelSizeBytes, 20);
    expect(c.state.chatHistorySizeBytes, 30);
    expect(c.state.mediaSizeBytes, 40);
    expect(c.state.otherSizeBytes, 50);
    expect(c.state.freeDiskBytes, 999);
    expect(c.state.totalNoteCount, 7);
    expect(c.state.deletableFeedNoteCount, 5);
    expect(c.state.conversationCount, 2);
    expect(c.state.ownPubkey, kSelfPub);
    expect(c.state.autoDeleteOldNotesDays, 30);
    expect(c.state.recentSyncWindowDays, 14);
    await c.close();
  });

  test(
    'loadStats with no identity stops loading and asks nothing else',
    () async {
      when(
        () => user.call(),
      ).thenAnswer((_) async => const Left(Failure.errorFailure('none')));
      final c = build();

      await c.loadStats();

      expect(c.state.isLoading, isFalse);
      verifyNever(() => stats.call(any()));
      await c.close();
    },
  );

  test('a failed stats read surfaces the error', () async {
    when(
      () => stats.call(any()),
    ).thenAnswer((_) async => const Left(Failure.errorFailure('disk')));
    final c = build();

    await c.loadStats();

    expect(c.state.isLoading, isFalse);
    expect(c.state.error, contains('disk'));
    await c.close();
  });

  test('missing settings fall back to off and 7 days', () async {
    when(
      () => getAuto.call(),
    ).thenAnswer((_) async => const Left(Failure.errorFailure('x')));
    when(
      () => getSync.call(),
    ).thenAnswer((_) async => const Left(Failure.errorFailure('x')));
    final c = build();

    await c.loadStats();

    expect(c.state.autoDeleteOldNotesDays, isNull);
    expect(c.state.recentSyncWindowDays, 7);
    await c.close();
  });

  test(
    'the auto-delete choice is saved and shown, and can be turned off',
    () async {
      final c = build();

      await c.setAutoDeleteOldNotesDays(14);
      expect(c.state.autoDeleteOldNotesDays, 14);
      await c.setAutoDeleteOldNotesDays(null);
      expect(c.state.autoDeleteOldNotesDays, isNull);

      verify(() => setAuto.call(14)).called(1);
      verify(() => setAuto.call(null)).called(1);
      await c.close();
    },
  );

  test('the sync window choice is saved and shown', () async {
    final c = build();

    await c.setRecentSyncWindowDays(30);

    expect(c.state.recentSyncWindowDays, 30);
    verify(() => setSync.call(30)).called(1);
    await c.close();
  });

  test('deleting feed notes needs an identity first', () async {
    final c = build();

    await c.deleteFeedNotes();

    verifyNever(() => deleteNotes.call(any()));
    await c.close();
  });

  test('deleting feed notes reports the count and reloads', () async {
    final c = build();
    await c.loadStats();

    await c.deleteFeedNotes();
    await pumpEventQueue();

    expect(c.state.isDeleting, isFalse);
    expect(c.state.deleteSuccess, isTrue);
    expect(c.state.deletedCount, 5);
    verify(() => deleteNotes.call(kSelfPub)).called(1);
    verify(() => stats.call(kSelfPub)).called(greaterThanOrEqualTo(2));
    await c.close();
  });

  test(
    'a failed feed-note delete shows the error and does not reload',
    () async {
      when(
        () => deleteNotes.call(any()),
      ).thenAnswer((_) async => const Left(Failure.errorFailure('locked')));
      final c = build();
      await c.loadStats();
      clearInteractions(stats);

      await c.deleteFeedNotes();

      expect(c.state.isDeleting, isFalse);
      expect(c.state.deleteSuccess, isFalse);
      expect(c.state.deleteError, contains('locked'));
      verifyNever(() => stats.call(any()));
      await c.close();
    },
  );

  test('deleting chat history succeeds and reloads', () async {
    final c = build();
    await c.loadStats();

    await c.deleteChatHistory();
    await pumpEventQueue();

    expect(c.state.isDeletingChatHistory, isFalse);
    expect(c.state.deleteChatHistorySuccess, isTrue);
    verify(() => deleteChats.call()).called(1);
    await c.close();
  });

  test('a failed chat-history delete shows the error', () async {
    when(
      () => deleteChats.call(),
    ).thenAnswer((_) async => const Left(Failure.errorFailure('busy')));
    final c = build();

    await c.deleteChatHistory();

    expect(c.state.isDeletingChatHistory, isFalse);
    expect(c.state.deleteChatHistorySuccess, isFalse);
    expect(c.state.deleteError, contains('busy'));
    await c.close();
  });
}
