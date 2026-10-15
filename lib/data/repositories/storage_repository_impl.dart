import 'dart:io';

import 'package:dartz/dartz.dart';
import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:injectable/injectable.dart';
import 'package:isar_community/isar.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/data/datasources/note_purge.dart';
import 'package:uniun/data/models/followed_note_model.dart';
import 'package:uniun/data/models/notes/note_model.dart';
import 'package:uniun/data/models/saved_note_model.dart';
import 'package:uniun/data/models/shiv_conversation_model.dart';
import 'package:uniun/data/models/shiv_message_model.dart';
import 'package:uniun/domain/entities/storage/storage_stats.dart';
import 'package:uniun/domain/repositories/storage_repository.dart';

// Top-level so compute() can send it to a background isolate. Returns
// (model, db, media, other). Files under `<dirPath>/media/*` go to the
// media bucket; everything else routes by filename.
(int model, int db, int media, int other) _scanDir(String dirPath) {
  const modelExtensions = {'.task', '.litertlm', '.bin', '.tflite'};
  const isarFilenames = {'default.isar', 'default.isar.lock'};

  int model = 0, db = 0, media = 0, other = 0;
  final dir = Directory(dirPath);
  if (!dir.existsSync()) return (0, 0, 0, 0);

  // Uses Platform.pathSeparator so Windows backslash paths also match.
  final mediaPrefix = '${dir.path}${Platform.pathSeparator}media${Platform.pathSeparator}';

  for (final entity in dir.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    int len;
    try {
      len = entity.lengthSync();
    } catch (_) {
      continue;
    }
    if (entity.path.startsWith(mediaPrefix)) {
      media += len;
      continue;
    }
    final name = entity.path.split(Platform.pathSeparator).last.toLowerCase();
    if (isarFilenames.contains(name)) {
      db += len;
    } else if (modelExtensions.any((e) => name.endsWith(e))) {
      model += len;
    } else {
      other += len;
    }
  }
  return (model, db, media, other);
}

@Injectable(as: StorageRepository)
class StorageRepositoryImpl implements StorageRepository {
  final Isar isar;

  StorageRepositoryImpl({required this.isar});

  @override
  Future<Either<Failure, StorageStats>> getStats(String ownPubkey) async {
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final supportDir = await getApplicationSupportDirectory();

      // Run heavy filesystem scans in background isolates in parallel.
      final results = await Future.wait([
        compute(_scanDir, docsDir.path),
        compute(_scanDir, supportDir.path),
      ]);

      final modelSize = results[0].$1 + results[1].$1;
      final dbSize = results[0].$2 + results[1].$2;
      final mediaSize = results[0].$3 + results[1].$3;
      final otherSize = results[0].$4 + results[1].$4;

      // These Isar queries must stay on the main isolate (Isar thread-affinity).
      final messages = await isar.shivMessageModels.where().findAll();
      final chatHistorySize =
          messages.fold<int>(0, (sum, m) => sum + m.content.length);
      final conversationCount = await isar.shivConversationModels.count();

      final totalNotes = await isar.noteModels.count();
      final savedIds = await isar.savedNoteModels
          .filter()
          .removedAtIsNull()
          .findAll()
          .then((list) => {for (final n in list) n.eventId});
      final followedIds = await isar.followedNoteModels
          .filter()
          .removedAtIsNull()
          .findAll()
          .then((list) => {for (final n in list) n.eventId});
      final topLevelNotes =
          await isar.noteModels.filter().rootEventIdIsNull().findAll();
      final deletableCount = topLevelNotes
          .where((n) =>
              n.authorPubkey != ownPubkey &&
              !savedIds.contains(n.eventId) &&
              !followedIds.contains(n.eventId))
          .length;

      final diskSpace = DiskSpacePlus();
      final freeMb = await diskSpace.getFreeDiskSpace ?? 0;
      final freeDiskBytes = (freeMb * 1024 * 1024).round();

      return Right(StorageStats(
        dbSizeBytes: dbSize,
        modelSizeBytes: modelSize,
        chatHistorySizeBytes: chatHistorySize,
        mediaSizeBytes: mediaSize,
        otherSizeBytes: otherSize,
        totalNoteCount: totalNotes,
        deletableFeedNoteCount: deletableCount,
        conversationCount: conversationCount,
        freeDiskBytes: freeDiskBytes,
      ));
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, int>> deleteFeedNotes(String ownPubkey) async {
    try {
      final savedIds = await isar.savedNoteModels
          .filter()
          .removedAtIsNull()
          .findAll()
          .then((list) => {for (final n in list) n.eventId});
      final followedIds = await isar.followedNoteModels
          .filter()
          .removedAtIsNull()
          .findAll()
          .then((list) => {for (final n in list) n.eventId});
      final topLevelNotes =
          await isar.noteModels.filter().rootEventIdIsNull().findAll();
      final deletable = topLevelNotes
          .where((n) =>
              n.authorPubkey != ownPubkey &&
              !savedIds.contains(n.eventId) &&
              !followedIds.contains(n.eventId))
          .toList();
      final toDelete = deletable.map((n) => n.id).toList();
      final toDeleteEventIds = deletable.map((n) => n.eventId).toList();

      if (toDelete.isEmpty) return const Right(0);

      await isar.writeTxn(() async {
        await purgeNotesInTxn(isar, toDeleteEventIds);
      });

      return Right(toDelete.length);
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, Unit>> deleteAllChatHistory() async {
    try {
      await isar.writeTxn(() async {
        await isar.shivMessageModels.clear();
        await isar.shivConversationModels.clear();
      });
      return const Right(unit);
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }
}
