import 'package:isar_community/isar.dart';

part 'pending_vector_delete_model.g.dart';

/// A note whose vector must be removed from the vector store.
///
/// Written in the same transaction that deletes the note, in whichever isolate
/// deletes it (the Gateway evicts notes; the vector store belongs to the main
/// isolate). The row is deleted only after the vector is gone, so a kill leaves
/// it for the next pass. An empty table means no vector is waiting.
@Collection(ignore: {'copyWith'})
@Name('PendingVectorDelete')
class PendingVectorDeleteModel {
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String eventId;

  late DateTime createdAt;
}
