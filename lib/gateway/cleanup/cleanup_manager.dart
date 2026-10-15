import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/core/notes/note_kinds.dart';
import 'package:uniun/data/datasources/note_purge.dart';
import 'package:uniun/data/models/draft_model.dart';
import 'package:uniun/data/models/followed_note_model.dart';
import 'package:uniun/data/models/gana_run_model.dart';
import 'package:uniun/data/models/media/media_cache_model.dart';
import 'package:uniun/data/models/notes/note_model.dart';
import 'package:uniun/data/models/saved_note_model.dart';

/// Periodic retention sweep — gateway-side, runs every [_interval].
///
/// Opt-in via `AppSettingsStore.autoDeleteOldNotesDays`. When `retention`
/// is null (the default), neither phase runs and nothing is deleted.
///
/// When enabled, two phases each tick:
///
/// 1. **Note eviction** — short-lived public traffic (Kind 1 / Kind 42)
///    older than [retention] is deleted, unless the note is own (matches
///    the active user's pubkey), saved (row in [SavedNoteModel]), or
///    followed (row in [FollowedNoteModel]). DMs (14/15), private-group
///    messages (9023), AI conversations, and profile / group metadata
///    are untouched.
///
/// 2. **Media GC** — after note eviction, any [MediaCacheModel] row whose
///    SHA is no longer referenced by any surviving note loses its file +
///    cache row. Media on saved / own / followed / DM / private-group
///    notes stays because those notes survive eviction.
class CleanupManager {
  CleanupManager({
    required this.isar,
    required this.activePubkey,
    this.retention,
  });

  final Isar isar;
  final String? activePubkey;

  /// User-configured retention. `null` = auto-cleanup disabled.
  final Duration? retention;

  static const Duration _interval = Duration(hours: 6);

  Timer? _timer;
  bool _running = false;

  void start() {
    if (_timer != null) return;
    if (retention == null) return; // Auto-cleanup disabled — never tick.
    _timer = Timer.periodic(_interval, (_) => unawaited(runOnce()));
    // First sweep on a short delay so we don't fight app launch.
    Future<void>.delayed(const Duration(minutes: 5), runOnce);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> runOnce() async {
    if (_running) return;
    _running = true;
    try {
      await _evictNotes();
      await _gcMedia();
      await _pruneGanaRuns();
      await _purgePublishedDraftTombstones();
    } catch (e, st) {
      debugPrint('CleanupManager run failed: $e\n$st');
    } finally {
      _running = false;
    }
  }

  // ── Phase 4: Published-draft tombstone retention ──────────────────────────
  //
  // When a draft is published we keep the row briefly as a UUID→event-id
  // pointer (see [DraftRepository.markPublished]) so other devices' inbound
  // handler can rewrite their `draftRefIds`. After this window the
  // tombstone is no longer useful — drop it.
  static const Duration _draftTombstoneRetention = Duration(days: 30);

  Future<void> _purgePublishedDraftTombstones() async {
    final cutoff = DateTime.now().subtract(_draftTombstoneRetention);
    final stale = await isar.draftModels
        .filter()
        .publishedAsEventIdIsNotNull()
        .updatedAtLessThan(cutoff)
        .findAll();
    if (stale.isEmpty) return;
    await isar.writeTxn(() async {
      for (final d in stale) {
        await isar.draftModels.delete(d.id);
      }
    });
  }

  // ── Phase 3: Gana run-log retention ─────────────────────────────────────
  //
  // Per ganas.md §1.7, the run log is a per-Gana ring (last 10) with a
  // hard global cap (1000). Cheap: a couple of indexed queries per Gana
  // every 6 hours.
  static const int _keepRunsPerGana = 10;
  static const int _ganaRunsGlobalCap = 1000;

  Future<void> _pruneGanaRuns() async {
    final allGanaIds = (await isar.ganaRunModels.where().findAll())
        .map((r) => r.ganaId)
        .toSet();
    if (allGanaIds.isEmpty) return;

    await isar.writeTxn(() async {
      for (final gid in allGanaIds) {
        final keep = await isar.ganaRunModels
            .filter()
            .ganaIdEqualTo(gid)
            .sortByStartedAtDesc()
            .limit(_keepRunsPerGana)
            .idProperty()
            .findAll();
        final keepSet = keep.toSet();
        final allIds = await isar.ganaRunModels
            .filter()
            .ganaIdEqualTo(gid)
            .idProperty()
            .findAll();
        final victims = allIds.where((i) => !keepSet.contains(i)).toList();
        if (victims.isNotEmpty) {
          await isar.ganaRunModels.deleteAll(victims);
        }
      }
      // Global cap — defensive against pathologically many Ganas.
      final total = await isar.ganaRunModels.count();
      if (total > _ganaRunsGlobalCap) {
        final overflow = await isar.ganaRunModels
            .where()
            .sortByStartedAt()
            .limit(total - _ganaRunsGlobalCap)
            .idProperty()
            .findAll();
        await isar.ganaRunModels.deleteAll(overflow);
      }
    });
  }

  // ── Phase 1: note eviction ──────────────────────────────────────────────

  Future<void> _evictNotes() async {
    final r = retention;
    if (r == null) return;
    final cutoff = DateTime.now().subtract(r);

    final savedIds = (await isar.savedNoteModels
            .filter()
            .removedAtIsNull()
            .findAll())
        .map((s) => s.eventId)
        .toSet();
    final followedIds = (await isar.followedNoteModels
            .filter()
            .removedAtIsNull()
            .findAll())
        .map((f) => f.eventId)
        .toSet();

    final ownPubkey = activePubkey;

    final staleKind1 = await isar.noteModels
        .filter()
        .kindEqualTo(kNoteKind)
        .createdLessThan(cutoff)
        .findAll();
    final staleKind42 = await isar.noteModels
        .filter()
        .kindEqualTo(kGroupMessageKind)
        .createdLessThan(cutoff)
        .findAll();
    final stale = [...staleKind1, ...staleKind42];
    if (stale.isEmpty) return;

    final toDelete = <String>[];
    for (final n in stale) {
      if (ownPubkey != null && n.authorPubkey == ownPubkey) continue;
      if (savedIds.contains(n.eventId)) continue;
      if (followedIds.contains(n.eventId)) continue;
      toDelete.add(n.eventId);
    }
    if (toDelete.isEmpty) return;

    await isar.writeTxn(() => purgeNotesInTxn(isar, toDelete));
  }

  // ── Phase 2: media GC ───────────────────────────────────────────────────

  /// Drops cache rows + on-disk files for SHAs no surviving note references.
  ///
  /// A SHA is considered "referenced" if any of:
  ///   • a live [NoteModel] row carries it (covers own / saved / followed /
  ///     DM / private-group notes — eviction skips those ids).
  ///   • a [SavedNoteModel] row carries it. Belt+suspenders: the saved row
  ///     owns its attachments independently of the live note, so future
  ///     manual storage purges can't orphan saved media.
  ///
  /// Followed-note media falls under bullet 1: the underlying live
  /// [NoteModel] is protected from eviction by the `followedIds` skip in
  /// [_evictNotes], so its `attachments` keep its SHAs in the set.
  Future<void> _gcMedia() async {
    if (retention == null) return;
    final caches = await isar.mediaCacheModels.where().findAll();
    if (caches.isEmpty) return;

    final referenced = <String>{};
    final survivors =
        await isar.noteModels.filter().hasMediaEqualTo(true).findAll();
    for (final n in survivors) {
      for (final a in n.attachments) {
        referenced.add(a.sha256);
      }
    }
    final saved =
        await isar.savedNoteModels.filter().removedAtIsNull().findAll();
    for (final s in saved) {
      for (final a in s.attachments) {
        referenced.add(a.sha256);
      }
    }

    final orphanIds = <int>[];
    final orphanPaths = <String>[];
    for (final c in caches) {
      if (referenced.contains(c.sha256)) continue;
      orphanIds.add(c.id);
      orphanPaths.add(c.localPath);
    }
    if (orphanIds.isEmpty) return;

    // Files first — a row pointing at a missing file is fine, the reverse
    // (file with no row) would slowly leak disk.
    for (final path in orphanPaths) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {
        // Best-effort; permissions / detached storage shouldn't block GC.
      }
    }

    await isar.writeTxn(() async {
      await isar.mediaCacheModels.deleteAll(orphanIds);
    });
  }
}
