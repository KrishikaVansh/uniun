import 'dart:async';
import 'dart:convert';

import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';
import 'package:isar_community/isar.dart';
import 'package:nip44/nip44.dart';
import 'package:nostr_core_dart/nostr.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/core/notes/note_kinds.dart';
import 'package:uniun/data/models/draft_model.dart';
import 'package:uniun/data/models/notes/note_model.dart';
import 'package:uniun/data/repositories/note_attachments_enricher.dart';
import 'package:uniun/domain/entities/draft/draft_entity.dart';
import 'package:uniun/domain/repositories/draft_repository.dart';
import 'package:uniun/domain/repositories/event_queue_repository.dart';
import 'package:uniun/domain/usecases/user_usecases.dart';

/// NIP-37 expiration window. Relays drop wraps after this; users who don't
/// open the app for 90 days lose any unsynced drafts (acceptable — local Isar
/// copy survives if they're still on the original device).
const Duration _draftExpiry = Duration(days: 90);

@Injectable(as: DraftRepository)
class DraftRepositoryImpl extends DraftRepository {
  final Isar isar;
  final EventQueueRepository _eventQueue;
  final GetActiveUserKeysUseCase _getActiveUserKeys;
  final NoteAttachmentsEnricher _attachments;

  DraftRepositoryImpl({
    required this.isar,
    required EventQueueRepository eventQueue,
    required GetActiveUserKeysUseCase getActiveUserKeys,
    required NoteAttachmentsEnricher attachments,
  })  : _eventQueue = eventQueue,
        _getActiveUserKeys = getActiveUserKeys,
        _attachments = attachments;

  /// Patch `localPath` onto the draft's staged attachments from the media
  /// cache so the draft renders like any note.
  Future<DraftEntity> _enrich(DraftEntity draft) async {
    if (draft.attachments.isEmpty) return draft;
    final blobs = await _attachments.enrichBlobs(draft.attachments);
    return draft.copyWith(attachments: blobs);
  }

  @override
  Future<Either<Failure, DraftEntity>> saveDraft(DraftEntity draft) async {
    try {
      final existing = await isar.draftModels
          .filter()
          .draftIdEqualTo(draft.draftId)
          .findFirst();

      final model = DraftModel()
        ..draftId = draft.draftId
        ..content = draft.content
        ..rootEventId = draft.rootEventId
        ..replyToEventId = draft.replyToEventId
        ..eTagRefs = draft.eTagRefs
        ..pTagRefs = draft.pTagRefs
        ..tTags = draft.tTags
        ..draftRefIds = draft.draftRefIds
        ..publishedAsEventId = draft.publishedAsEventId
        ..attachments = [for (final a in draft.attachments) a.toAttachment()]
        ..createdAt = draft.createdAt
        ..updatedAt = draft.updatedAt
        ..lastSyncedCreatedAt = existing?.lastSyncedCreatedAt;

      await isar.writeTxn(() async {
        if (existing != null) model.id = existing.id;
        await isar.draftModels.put(model);
      });

      // Await the publish so it's durably enqueued before we return — but
      // never let a publish failure surface as a save failure. Local Isar is
      // the source of truth; the relay is best-effort sync. Draft media is
      // local-only, so the wrap carries text + tags but no `imeta`.
      await _publishDraftWrap(model);

      return Right(await _enrich(model.toDomain()));
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, List<DraftEntity>>> getDrafts() async {
    try {
      // Tombstones (`publishedAsEventId` set) are hidden from the drafts list
      // — they exist only as UUID→event-id mappings for cross-device
      // reconciliation and never resurface to the user as drafts.
      final drafts = await isar.draftModels
          .filter()
          .publishedAsEventIdIsNull()
          .sortByUpdatedAtDesc()
          .findAll();
      return Right([
        for (final d in drafts) await _enrich(d.toDomain()),
      ]);
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, List<DraftEntity>>> getDraftsReferencing(
    String draftId,
  ) async {
    try {
      final drafts = await isar.draftModels
          .filter()
          .draftRefIdsElementEqualTo(draftId)
          .publishedAsEventIdIsNull()
          .sortByCreatedAt()
          .findAll();
      return Right([
        for (final d in drafts) await _enrich(d.toDomain()),
      ]);
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, DraftEntity>> getDraftById(String draftId) async {
    try {
      final draft =
          await isar.draftModels.filter().draftIdEqualTo(draftId).findFirst();
      if (draft == null) {
        return const Left(Failure.notFoundFailure('Draft not found'));
      }
      return Right(await _enrich(draft.toDomain()));
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, Unit>> markPublished({
    required String draftId,
    required String eventId,
  }) async {
    try {
      final row = await isar.draftModels
          .filter()
          .draftIdEqualTo(draftId)
          .findFirst();
      if (row == null) return const Right(unit);
      await isar.writeTxn(() async {
        row.publishedAsEventId = eventId;
        row.updatedAt = DateTime.now();
        await isar.draftModels.put(row);
      });
      // Republish the wrap so the UUID→event-id mapping reaches other devices.
      // Best-effort — local row is the source of truth.
      await _publishDraftWrap(row);
      // Local sweep: any other draft on this device referencing this UUID is
      // promoted now, so a future publish here uses the real event id.
      await _rewriteLocalRefs(draftUuid: draftId, eventId: eventId);
      return const Right(unit);
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, Unit>> rewriteDraftRefs({
    required String draftUuid,
    required String eventId,
  }) async {
    try {
      await _rewriteLocalRefs(draftUuid: draftUuid, eventId: eventId);
      return const Right(unit);
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  /// Internal sweep — extracted so [markPublished] (local publish) and
  /// [rewriteDraftRefs] (inbound from another device) share one code path.
  Future<void> _rewriteLocalRefs({
    required String draftUuid,
    required String eventId,
  }) async {
    final referencing = await isar.draftModels
        .filter()
        .draftRefIdsElementEqualTo(draftUuid)
        .findAll();
    if (referencing.isEmpty) return;
    await isar.writeTxn(() async {
      for (final d in referencing) {
        d.draftRefIds =
            d.draftRefIds.where((r) => r != draftUuid).toList();
        if (!d.eTagRefs.contains(eventId)) {
          d.eTagRefs = [...d.eTagRefs, eventId];
        }
        d.updatedAt = DateTime.now();
        await isar.draftModels.put(d);
      }
    });
    // Republish each modified wrap so the new linkage syncs.
    for (final d in referencing) {
      await _publishDraftWrap(d);
    }
  }

  @override
  Future<Either<Failure, int>> purgePublishedTombstonesOlderThan(
    Duration retention,
  ) async {
    try {
      final cutoff = DateTime.now().subtract(retention);
      final stale = await isar.draftModels
          .filter()
          .publishedAsEventIdIsNotNull()
          .updatedAtLessThan(cutoff)
          .findAll();
      if (stale.isEmpty) return const Right(0);
      await isar.writeTxn(() async {
        for (final d in stale) {
          await isar.draftModels.delete(d.id);
        }
      });
      return Right(stale.length);
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, Unit>> deleteDraft(String draftId) async {
    try {
      await isar.writeTxn(() async {
        await isar.draftModels.filter().draftIdEqualTo(draftId).deleteAll();
      });
      // NIP-37 deletion signal: publish a Kind 31234 with empty content under
      // the same `d` tag. Receivers drop their local row. Same suppression
      // policy as saveDraft — publish failures don't roll back the local
      // delete.
      await _publishDraftDeletion(draftId);
      return const Right(unit);
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  // ── Outbound NIP-37 wraps ─────────────────────────────────────────────────

  /// Builds, signs, and enqueues a Kind 31234 wrap carrying the encrypted
  /// inner draft event. Idempotent — re-saving the same draft replaces the
  /// previous relay-side copy because Kind 31234 is parameterized replaceable
  /// keyed on `["d", draftId]`. Swallows all errors; the local Isar write is
  /// authoritative and the relay is best-effort sync.
  Future<void> _publishDraftWrap(DraftModel m) async {
    try {
    final keysResult = await _getActiveUserKeys.call();
    final keys = keysResult.fold((_) => null, (k) => k);
    if (keys == null) return;

    final innerEvent = <String, dynamic>{
      'kind': kNoteKind,
      'pubkey': keys.pubkeyHex,
      'created_at': m.updatedAt.millisecondsSinceEpoch ~/ 1000,
      'tags': [
        if (m.rootEventId != null) ['e', m.rootEventId!, '', 'root'],
        if (m.replyToEventId != null) ['e', m.replyToEventId!, '', 'reply'],
        for (final e in m.eTagRefs)
          if (e != m.rootEventId && e != m.replyToEventId)
            ['e', e, '', 'mention'],
        for (final p in m.pTagRefs) ['p', p],
        for (final t in m.tTags) ['t', t],
        // App-private tags below: receivers (our own clients) read these to
        // reconstruct the draft graph; nothing else in the Nostr ecosystem
        // looks at them.
        for (final ref in m.draftRefIds) ['d-ref', ref],
        if (m.publishedAsEventId != null)
          ['published-as', m.publishedAsEventId!],
      ],
      'content': m.content,
    };

    final encrypted = await Nip44.encryptMessage(
      jsonEncode(innerEvent),
      keys.privkeyHex,
      keys.pubkeyHex,
    );

    await _enqueueWrap(
      keys: keys,
      draftId: m.draftId,
      encryptedContent: encrypted,
    );
    } catch (_) {
      // Suppress — local Isar write already succeeded.
    }
  }

  /// NIP-37 deletion: same `d` tag, empty content. Relay replaces the previous
  /// row; receivers see empty content and drop the local draft. Errors
  /// swallowed for the same reason as [_publishDraftWrap].
  Future<void> _publishDraftDeletion(String draftId) async {
    try {
      final keysResult = await _getActiveUserKeys.call();
      final keys = keysResult.fold((_) => null, (k) => k);
      if (keys == null) return;
      await _enqueueWrap(
        keys: keys,
        draftId: draftId,
        encryptedContent: '',
      );
    } catch (_) {
      // Suppress — local Isar delete already succeeded.
    }
  }

  Future<void> _enqueueWrap({
    required UserSigningKeys keys,
    required String draftId,
    required String encryptedContent,
  }) async {
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expireSec =
        DateTime.now().add(_draftExpiry).millisecondsSinceEpoch ~/ 1000;

    // Canonical tag order — must match
    // [EventQueueModel.toSerializedRelayMessage]: d → k → expiration.
    final tags = <List<String>>[
      ['d', draftId],
      ['k', kNoteKind.toString()],
      ['expiration', expireSec.toString()],
    ];

    final event = Event.from(
      privkey: keys.privkeyHex,
      kind: kDraftWrapKind,
      content: encryptedContent,
      tags: tags,
      createdAt: nowSec,
    );

    await _eventQueue.enqueueSignedEvent(
      eventId: event.id,
      authorPubkey: event.pubkey,
      sig: event.sig,
      kind: kDraftWrapKind,
      eTagRefs: const [],
      pTagRefs: const [],
      tTags: const [],
      content: event.content,
      created: DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000),
      dTag: draftId,
      quoteKind: kNoteKind,
      expirationSec: expireSec,
    );
  }
}

