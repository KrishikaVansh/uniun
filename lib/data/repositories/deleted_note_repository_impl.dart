import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/data/datasources/note_purge.dart';
import 'package:uniun/data/models/deleted_note_model.dart';
import 'package:uniun/domain/repositories/deleted_note_repository.dart';

@Injectable(as: DeletedNoteRepository)
class DeletedNoteRepositoryImpl extends DeletedNoteRepository {
  final Isar isar;
  DeletedNoteRepositoryImpl({required this.isar});

  @override
  Future<Either<Failure, Unit>> deleteNote(String eventId) async {
    try {
      final existing = await isar.deletedNoteModels
          .where()
          .eventIdEqualTo(eventId)
          .findFirst();

      final row = (existing ?? DeletedNoteModel())
        ..eventId = eventId
        ..deletedAt = DateTime.now()
        ..signedNostrEvent = null
        ..removedAt = null;

      await isar.writeTxn(() async {
        await isar.deletedNoteModels.put(row);

        // The note, its feed projection, relation edges (so neighbours' reply
        // counts stay right), its knowledge and its queued vector delete.
        await purgeNotesInTxn(isar, [eventId]);
      });
      return const Right(unit);
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }
}
