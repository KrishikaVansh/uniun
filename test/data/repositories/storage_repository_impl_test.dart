import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/data/models/pending_vector_delete_model.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:uniun/data/models/followed_note_model.dart';
import 'package:uniun/data/models/notes/note_model.dart';
import 'package:uniun/data/models/notes/unread_note_model.dart';
import 'package:uniun/data/models/saved_note_model.dart';
import 'package:uniun/data/models/shiv_conversation_model.dart';
import 'package:uniun/data/models/shiv_message_model.dart';
import 'package:uniun/data/repositories/storage_repository_impl.dart';
import 'package:uniun/domain/entities/storage/storage_stats.dart';

import '../../_helpers/fake_path_provider.dart';
import '../../_helpers/fixtures.dart';
import '../../_helpers/isar_seeds.dart';
import '../../_helpers/isar_test_harness.dart';

/// Covers: StorageRepositoryImpl getStats (bucket routing of the filesystem
/// scan, chat history size, deletable-note counting, free disk), the
/// deleteFeedNotes retention rules (own / saved / followed / reply survive),
/// and deleteAllChatHistory.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Isar isar;
  late StorageRepositoryImpl repo;
  late Directory docsDir;
  late Directory supportDir;

  setUp(() async {
    isar = await openTestIsar();
    repo = StorageRepositoryImpl(isar: isar);

    docsDir = await Directory.systemTemp.createTemp('uniun_storage_docs');
    supportDir = await Directory.systemTemp.createTemp('uniun_storage_sup');
    PathProviderPlatform.instance =
        FakePathProviderPlatform(docs: docsDir.path, support: supportDir.path);

    // disk_space_plus talks over a raw method channel — return 100 MB free.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('disk_space_plus'),
            (call) async => 100.0);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('disk_space_plus'), null);
    await isar.close(deleteFromDisk: true);
    await docsDir.delete(recursive: true);
    await supportDir.delete(recursive: true);
  });

  Future<void> writeFile(Directory dir, String relPath, int bytes) async {
    final f = File('${dir.path}${Platform.pathSeparator}'
        '${relPath.replaceAll('/', Platform.pathSeparator)}');
    await f.create(recursive: true);
    await f.writeAsBytes(List.filled(bytes, 0));
  }

  StorageStats statsOf(dynamic either) =>
      either.getOrElse(() => throw 'expected Right') as StorageStats;

  group('getStats — filesystem buckets', () {
    test('routes media/ files, isar db files, model files, and other',
        () async {
      await writeFile(docsDir, 'media/a.jpg', 100);
      await writeFile(docsDir, 'media/nested/b.mp4', 50);
      await writeFile(docsDir, 'default.isar', 300);
      await writeFile(docsDir, 'default.isar.lock', 10);
      await writeFile(supportDir, 'gemma.task', 500);
      await writeFile(supportDir, 'qwen.litertlm', 200);
      await writeFile(docsDir, 'random.txt', 7);

      final stats = statsOf(await repo.getStats(kSelfPub));
      expect(stats.mediaSizeBytes, 150);
      expect(stats.dbSizeBytes, 310);
      expect(stats.modelSizeBytes, 700);
      expect(stats.otherSizeBytes, 7);
    });

    test('sums across BOTH docs and support directories', () async {
      await writeFile(docsDir, 'a.task', 100);
      await writeFile(supportDir, 'b.task', 200);
      final stats = statsOf(await repo.getStats(kSelfPub));
      expect(stats.modelSizeBytes, 300);
    });

    test('empty directories → all zeros', () async {
      final stats = statsOf(await repo.getStats(kSelfPub));
      expect(stats.mediaSizeBytes, 0);
      expect(stats.dbSizeBytes, 0);
      expect(stats.modelSizeBytes, 0);
      expect(stats.otherSizeBytes, 0);
    });

    test('free disk converts MB → bytes', () async {
      final stats = statsOf(await repo.getStats(kSelfPub));
      expect(stats.freeDiskBytes, 100 * 1024 * 1024);
    });
  });

  group('getStats — Isar-derived counts', () {
    test('chat history size = sum of message content lengths; '
        'conversation count from its collection', () async {
      await isar.writeTxn(() async {
        await isar.shivConversationModels.put(shivConversationRow('c-1'));
        await isar.shivConversationModels.put(shivConversationRow('c-2'));
        await isar.shivMessageModels
            .put(shivMessageRow('m-1', content: 'abcde')); // 5
        await isar.shivMessageModels
            .put(shivMessageRow('m-2', content: 'xy')); // 2
      });
      final stats = statsOf(await repo.getStats(kSelfPub));
      expect(stats.chatHistorySizeBytes, 7);
      expect(stats.conversationCount, 2);
    });

    test('deletable count excludes own, saved, followed, and replies',
        () async {
      await seedNoteRow(isar, 'deletable', authorPubkey: kAlicePub);
      await seedNoteRow(isar, 'own-note', authorPubkey: kSelfPub);
      await seedNoteRow(isar, 'saved-note', authorPubkey: kAlicePub);
      await seedNoteRow(isar, 'followed-note', authorPubkey: kBobPub);
      await seedNoteRow(isar, 'a-reply',
          authorPubkey: kAlicePub,
          rootEventId: 'deletable',
          replyToEventId: 'deletable');
      await isar.writeTxn(() async {
        await isar.savedNoteModels.put(savedNoteRow('saved-note'));
        await isar.followedNoteModels.put(followedNoteSeed('followed-note'));
      });

      final stats = statsOf(await repo.getStats(kSelfPub));
      expect(stats.totalNoteCount, 5);
      expect(stats.deletableFeedNoteCount, 1);
    });
  });

  group('deleteFeedNotes', () {
    test('purges only foreign, unsaved, unfollowed top-level notes '
        '+ their unread rows', () async {
      await seedNoteRow(isar, 'gone-1', authorPubkey: kAlicePub);
      await seedNoteRow(isar, 'gone-2', authorPubkey: kBobPub);
      await seedNoteRow(isar, 'own-note', authorPubkey: kSelfPub);
      await seedNoteRow(isar, 'saved-note', authorPubkey: kAlicePub);
      await seedNoteRow(isar, 'followed-note', authorPubkey: kBobPub);
      await seedNoteRow(isar, 'a-reply',
          authorPubkey: kAlicePub,
          rootEventId: 'own-note',
          replyToEventId: 'own-note');
      await seedUnreadRow(isar, 'gone-1');
      await seedUnreadRow(isar, 'own-note');
      await isar.writeTxn(() async {
        await isar.savedNoteModels.put(savedNoteRow('saved-note'));
        await isar.followedNoteModels.put(followedNoteSeed('followed-note'));
      });

      final r = await repo.deleteFeedNotes(kSelfPub);
      expect(r.getOrElse(() => -1), 2);

      final remaining = (await isar.noteModels.where().findAll())
          .map((n) => n.eventId)
          .toSet();
      expect(remaining, {'own-note', 'saved-note', 'followed-note', 'a-reply'});

      // Unread orphan for the purged note is gone; the survivor's stays.
      final unread = (await isar.unreadNoteModels.where().findAll())
          .map((u) => u.eventId)
          .toList();
      expect(unread, ['own-note']);
    });

    test('every purged note queues its vector delete, survivors do not',
        () async {
      await seedNoteRow(isar, 'gone-1', authorPubkey: kAlicePub);
      await seedNoteRow(isar, 'own-note', authorPubkey: kSelfPub);

      await repo.deleteFeedNotes(kSelfPub);

      expect(
        (await isar.pendingVectorDeleteModels.where().findAll())
            .map((r) => r.eventId),
        ['gone-1'],
      );
    });

    test('nothing deletable → Right(0), database untouched', () async {
      await seedNoteRow(isar, 'own-note', authorPubkey: kSelfPub);
      final r = await repo.deleteFeedNotes(kSelfPub);
      expect(r.getOrElse(() => -1), 0);
      expect(await isar.noteModels.count(), 1);
    });

    test('empty database → Right(0)', () async {
      expect((await repo.deleteFeedNotes(kSelfPub)).getOrElse(() => -1), 0);
    });

    test('getStats deletable count matches what deleteFeedNotes removes '
        '(the two share one predicate)', () async {
      for (var i = 0; i < 5; i++) {
        await seedNoteRow(isar, 'n-$i', authorPubkey: kAlicePub);
      }
      await seedNoteRow(isar, 'own-note', authorPubkey: kSelfPub);

      final predicted =
          statsOf(await repo.getStats(kSelfPub)).deletableFeedNoteCount;
      final deleted =
          (await repo.deleteFeedNotes(kSelfPub)).getOrElse(() => -1);
      expect(deleted, predicted);
      expect(
          statsOf(await repo.getStats(kSelfPub)).deletableFeedNoteCount, 0);
    });
  });

  group('deleteAllChatHistory', () {
    test('clears both message and conversation collections', () async {
      await isar.writeTxn(() async {
        await isar.shivConversationModels.put(shivConversationRow('c-1'));
        await isar.shivMessageModels.put(shivMessageRow('m-1'));
        await isar.shivMessageModels
            .put(shivMessageRow('m-2', conversationId: 'c-1'));
      });

      final r = await repo.deleteAllChatHistory();
      expect(r.isRight(), isTrue);
      expect(await isar.shivMessageModels.count(), 0);
      expect(await isar.shivConversationModels.count(), 0);
    });

    test('idempotent on empty collections', () async {
      expect((await repo.deleteAllChatHistory()).isRight(), isTrue);
    });
  });
}
