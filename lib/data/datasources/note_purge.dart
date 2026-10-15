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

  // Every key below is indexed, so each id is an index lookup rather than a
  // scan: a retention sweep can evict thousands of notes in one transaction.
  await isar.noteModels.deleteAllByEventId(ids);
  await isar.unreadNoteModels.deleteAllByEventId(ids);
  for (final id in ids) {
    await isar.noteRelationModels.where().parentIdEqualToAnyChildId(id).deleteAll();
    await isar.noteRelationModels.where().childIdEqualTo(id).deleteAll();
  }

  final gone = <String>[];
  for (final id in ids) {
    final saved = await isar.savedNoteModels.getByEventId(id);
    if (saved == null || saved.removedAt != null) gone.add(id);
  }
  if (gone.isEmpty) return;

  await isar.pendingEmbeddingModels.deleteAllByEventId(gone);
  await isar.pendingExtractionModels.deleteAllByNoteId(gone);
  await isar.memoryNodeModels.deleteAllByNoteId(gone);

  // One pass over the memories that link to anything: the list field has no
  // index, and a scan per deleted id would be quadratic.
  final goneSet = gone.toSet();
  final linking = <MemoryNodeModel>[];
  for (final m in await isar.memoryNodeModels
      .filter()
      .linkedNoteIdsIsNotEmpty()
      .findAll()) {
    if (m.linkedNoteIds.any(goneSet.contains)) {
      m.linkedNoteIds =
          m.linkedNoteIds.where((l) => !goneSet.contains(l)).toList();
      linking.add(m);
    }
  }
  if (linking.isNotEmpty) await isar.memoryNodeModels.putAll(linking);

  final keys = <String>{};
  final edgeIds = <int>[];
  for (final id in gone) {
    for (final e
        in await isar.graphEdgeModels.where().sourceNoteIdEqualTo(id).findAll()) {
      edgeIds.add(e.id);
      keys
        ..add(e.sourceKey)
        ..add(e.targetKey);
    }
  }
  if (edgeIds.isNotEmpty) {
    await isar.graphEdgeModels.deleteAll(edgeIds);
    for (final key in keys) {
      final used = await isar.graphEdgeModels.where().sourceKeyEqualToAnyRelationType(key).count() +
          await isar.graphEdgeModels.where().targetKeyEqualTo(key).count();
      if (used == 0) await isar.graphNodeModels.deleteByKey(key);
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
