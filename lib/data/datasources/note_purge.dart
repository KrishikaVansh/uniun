import 'package:isar_community/isar.dart';
import 'package:uniun/data/models/graph_edge_model.dart';
import 'package:uniun/data/models/graph_node_model.dart';
import 'package:uniun/data/models/memory_node_model.dart';
import 'package:uniun/data/models/note_relation_model.dart';
import 'package:uniun/data/models/notes/note_model.dart';
import 'package:uniun/data/models/notes/unread_note_model.dart';
import 'package:uniun/data/models/pending_embedding_model.dart';
import 'package:uniun/data/models/pending_extraction_model.dart';
import 'package:uniun/data/models/pending_vector_delete_model.dart';
import 'package:uniun/data/models/saved_note_model.dart';

/// The one way a note leaves the device: deletes the notes [eventIds] and what
/// was derived from them, and queues their vectors for removal.
///
/// Call it inside the caller's `isar.writeTxn`, so the note and its leftovers
/// go together or not at all. It runs in whichever isolate deletes the note;
/// only Isar is touched, the vector itself is removed later by
/// `NoteVectorCleanupWorker` in the isolate that owns the store.
///
/// A note that is still saved keeps its vector, memory and graph edges: the
/// saved copy is what Shiv reads. Connected notes are never changed, apart
/// from dropping the deleted id from their linked ids; a concept stays while
/// any edge still uses it.
Future<void> purgeNotesInTxn(Isar isar, Iterable<String> eventIds) async {
  final ids = eventIds.toSet().toList();
  if (ids.isEmpty) return;

  await isar.noteModels
      .filter()
      .anyOf(ids, (q, id) => q.eventIdEqualTo(id))
      .deleteAll();
  await isar.unreadNoteModels
      .filter()
      .anyOf(ids, (q, id) => q.eventIdEqualTo(id))
      .deleteAll();
  await isar.noteRelationModels
      .filter()
      .anyOf(ids, (q, id) => q.parentIdEqualTo(id))
      .or()
      .anyOf(ids, (q, id) => q.childIdEqualTo(id))
      .deleteAll();

  final stillSaved = (await isar.savedNoteModels
          .filter()
          .removedAtIsNull()
          .anyOf(ids, (q, id) => q.eventIdEqualTo(id))
          .findAll())
      .map((s) => s.eventId)
      .toSet();
  final gone = ids.where((id) => !stillSaved.contains(id)).toList();
  if (gone.isEmpty) return;

  await isar.pendingEmbeddingModels
      .filter()
      .anyOf(gone, (q, id) => q.eventIdEqualTo(id))
      .deleteAll();
  await isar.pendingExtractionModels
      .filter()
      .anyOf(gone, (q, id) => q.noteIdEqualTo(id))
      .deleteAll();
  await isar.memoryNodeModels
      .filter()
      .anyOf(gone, (q, id) => q.noteIdEqualTo(id))
      .deleteAll();

  final linking = await isar.memoryNodeModels
      .filter()
      .anyOf(gone, (q, id) => q.linkedNoteIdsElementEqualTo(id))
      .findAll();
  for (final m in linking) {
    m.linkedNoteIds = m.linkedNoteIds.where((l) => !gone.contains(l)).toList();
  }
  if (linking.isNotEmpty) await isar.memoryNodeModels.putAll(linking);

  final edges = await isar.graphEdgeModels
      .filter()
      .anyOf(gone, (q, id) => q.sourceNoteIdEqualTo(id))
      .findAll();
  if (edges.isNotEmpty) {
    await isar.graphEdgeModels.deleteAll([for (final e in edges) e.id]);
    final keys = {
      for (final e in edges) ...[e.sourceKey, e.targetKey],
    };
    for (final key in keys) {
      final used = await isar.graphEdgeModels
          .filter()
          .sourceKeyEqualTo(key)
          .or()
          .targetKeyEqualTo(key)
          .count();
      if (used == 0) {
        await isar.graphNodeModels.filter().keyEqualTo(key).deleteAll();
      }
    }
  }

  final now = DateTime.now();
  await isar.pendingVectorDeleteModels.putAll([
    for (final id in gone)
      PendingVectorDeleteModel()
        ..eventId = id
        ..createdAt = now,
  ]);
}
