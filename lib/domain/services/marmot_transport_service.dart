import 'dart:async';
import 'dart:convert';
import 'package:nostr_core_dart/nostr.dart';
import 'package:uniun/core/enum/note_type.dart';
import 'package:uniun/core/notes/embedded_note_codec.dart';
import 'package:uniun/core/notes/note_kinds.dart';
import 'package:uniun/domain/entities/event_queue/queued_event_entity.dart';
import 'package:uniun/domain/entities/media/media_blob_entity.dart';
import 'package:uniun/domain/entities/media/media_dim.dart';
import 'package:uniun/domain/entities/note/note_entity.dart';
import 'package:uniun/domain/entities/private_group/private_group_entity.dart';
import 'package:uniun/domain/repositories/e2ee_group_repository.dart';
import 'package:uniun/domain/repositories/profile_repository.dart';
import 'package:uniun/domain/services/marmot_mls_service.dart';

import 'package:injectable/injectable.dart';

@lazySingleton
class MarmotTransportService {
  final E2EEGroupRepository _groups;
  final MarmotMlsService _mlsService;
  final ProfileRepository _profiles;
  StreamSubscription<void>? _subscription;
  Future<void>? _processing;
  bool _again = false;
  bool _stopping = false;

  MarmotTransportService(
    this._groups,
    this._mlsService,
    this._profiles,
  );

  void start() {
    if (_subscription != null) return;
    _stopping = false;
    unawaited(_processLoop());
    _subscription = _groups.watchPendingMessages().listen((_) {
      unawaited(_processLoop());
    });
  }

  Future<void> stop() async {
    _stopping = true;
    await _subscription?.cancel();
    _subscription = null;
    await _processing;
  }

  Future<void> _processLoop() async {
    if (_stopping) return;
    if (_processing != null) {
      _again = true;
      return;
    }
    final processing = () async {
      do {
        _again = false;
        await _processPendingMessages();
      } while (_again && !_stopping);
    }();
    _processing = processing;
    try {
      await processing;
    } finally {
      _processing = null;
    }
  }

  Future<PrivateGroupEntity?> _findGroup(String groupId) =>
      _groups.findGroup(groupId);

  Future<void> _processPendingMessages() async {
    final pending = await _groups.pendingMessages();
    if (pending.isEmpty) return;

    for (final encrypted in pending) {
      try {
        if (encrypted.kind == 9024) {
          final joinedMlsGroupIdB64 = await _mlsService.joinGroupFromWelcome(
            welcomeB64: encrypted.encryptedPayload,
          );
          // Confirms real membership on THIS device; stays queued when the
          // group is not stored yet.
          await _groups.confirmWelcome(
            pendingId: encrypted.id,
            groupId: encrypted.groupId,
            mlsGroupId: joinedMlsGroupIdB64,
          );
          continue;
        }

        if (encrypted.kind == 9025) {
          final group = await _findGroup(encrypted.groupId);
          if (group == null || group.mlsGroupId.isEmpty) {
            // Wait until welcome has populated mlsGroupId.
            continue;
          }
          await _mlsService.processProtocolMessage(
            groupId: group.mlsGroupId,
            base64Payload: encrypted.encryptedPayload,
            groupIdIsBase64: true,
          );
          await _groups.discardPendingMessage(encrypted.id);
          continue;
        }

        if (encrypted.kind == 9022) {
          await _groups.discardPendingMessage(encrypted.id);
          continue;
        }

        final group = await _findGroup(encrypted.groupId);
        if (group == null || group.mlsGroupId.isEmpty) {
          continue;
        }

        final decryptedBytes = await _mlsService.decryptMessage(
          groupId: group.mlsGroupId,
          base64Payload: encrypted.encryptedPayload,
          groupIdIsBase64: true,
        );

        final envelope = _decodeMessageEnvelope(utf8.decode(decryptedBytes));

        final decryptedMsg = NoteEntity(
          id: encrypted.eventId,
          sig: '',
          authorPubkey: encrypted.senderPubkey,
          content: envelope.content,
          kind: kPrivateGroupKind,
          sourcePrivateGroupId: encrypted.groupId,
          type: envelope.attachments.any((a) => a.mime.startsWith('image/'))
              ? NoteType.image
              : NoteType.text,
          eTagRefs: envelope.eTagRefs,
          rootEventId: envelope.rootEventId,
          replyToEventId: envelope.replyToEventId,
          pTagRefs: const [],
          tTags: const [],
          created: encrypted.timestamp,
          embeddedNoteJson: envelope.embeddedNoteJson,
          attachments: envelope.attachments,
        );

        // Reference edges (eTagRefs are currently empty on decrypted MLS
        // payloads) go through the shared edge table in the same transaction.
        await _groups.saveDecryptedMessage(
          pendingId: encrypted.id,
          message: decryptedMsg,
        );
        // Flag the sender for profile fetch if unknown. The profiles
        // subscription fills the username so the NoteCard stops showing the
        // raw pubkey.
        await _profiles.requestProfileFetch(decryptedMsg.authorPubkey);
      } catch (e) {
        // Leave in queue if epoch mismatch or other retryable error.
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────────────────

  /// Encodes a message body + its reference ids + NIP-10 threading markers +
  /// NIP-92 imeta attachments into the encrypted MLS payload. Plain text is
  /// sent verbatim when there is no metadata (backward compatible); otherwise
  /// a small JSON envelope carries the e-tag ids (`e`), the root marker
  /// (`r`), the reply marker (`y`), the embed-by-value snapshot (`em`), and the
  /// imeta list (`i`). Receiver-side decryption rebuilds the note's attachments
  /// from `i` and the embed from `em`.
  String _encodeMessageEnvelope(
    String content,
    List<String> eTagRefs, {
    String? rootEventId,
    String? replyToEventId,
    String? embeddedNoteJson,
    List<MediaBlobEntity> attachments = const [],
  }) {
    if (eTagRefs.isEmpty &&
        rootEventId == null &&
        replyToEventId == null &&
        embeddedNoteJson == null &&
        attachments.isEmpty) {
      return content;
    }
    return jsonEncode({
      'c': content,
      'e': eTagRefs,
      if (rootEventId != null) 'r': rootEventId,
      if (replyToEventId != null) 'y': replyToEventId,
      if (embeddedNoteJson != null) 'em': embeddedNoteJson,
      if (attachments.isNotEmpty)
        'i': [
          for (final a in attachments)
            {
              'x': a.sha256,
              'm': a.mime,
              if (a.sizeBytes > 0) 's': a.sizeBytes,
              if (a.serverUrls.isNotEmpty) 'u': a.serverUrls.first,
              if (a.dim != null) 'w': a.dim!.width,
              if (a.dim != null) 'h': a.dim!.height,
              if (a.blurhash != null) 'b': a.blurhash,
              if (a.filename != null) 'n': a.filename,
            },
        ],
    });
  }

  /// Inverse of [_encodeMessageEnvelope]. Legacy/plain payloads decode to the
  /// raw text with no references / markers / attachments.
  ({
    String content,
    List<String> eTagRefs,
    String? rootEventId,
    String? replyToEventId,
    String? embeddedNoteJson,
    List<MediaBlobEntity> attachments,
  }) _decodeMessageEnvelope(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map &&
          decoded['c'] is String &&
          decoded['e'] is List) {
        final rawImeta = decoded['i'];
        final attachments = <MediaBlobEntity>[];
        if (rawImeta is List) {
          for (final m in rawImeta) {
            if (m is! Map) continue;
            final sha = m['x'];
            final mime = m['m'];
            if (sha is! String || mime is! String) continue;
            final url = m['u'] as String?;
            final width = m['w'] as int?;
            final height = m['h'] as int?;
            attachments.add(MediaBlobEntity(
              sha256: sha,
              mime: mime,
              sizeBytes: (m['s'] as int?) ?? 0,
              serverUrls: url != null ? [url] : const [],
              dim: (width != null && height != null)
                  ? MediaDim(width: width, height: height)
                  : null,
              blurhash: m['b'] as String?,
              filename: m['n'] as String?,
            ));
          }
        }
        final rawEmbed = decoded['em'] as String?;
        return (
          content: decoded['c'] as String,
          eTagRefs: (decoded['e'] as List).cast<String>(),
          rootEventId: decoded['r'] as String?,
          replyToEventId: decoded['y'] as String?,
          // Embed-by-value share — verify the snapshot once, here at the edge.
          embeddedNoteJson:
              rawEmbed == null ? null : EmbeddedNoteCodec.verifyAndSanitize(rawEmbed),
          attachments: attachments,
        );
      }
    } catch (_) {
      // Not an envelope — fall through to plain text.
    }
    return (
      content: raw,
      eTagRefs: const <String>[],
      rootEventId: null,
      replyToEventId: null,
      embeddedNoteJson: null,
      attachments: const <MediaBlobEntity>[],
    );
  }

  /// Builds the queue entry for a fully-signed Marmot [Event]. The
  /// `["h", groupId]` tag is extracted so the queue's serializer can
  /// reproduce it at send time.
  QueuedEventEntity _buildQueueEntry(Event event) {
    String? hTag;
    for (final t in event.tags) {
      if (t.isEmpty) continue;
      if (t[0] == 'h' && t.length > 1) {
        hTag = t[1];
        break;
      }
    }
    return QueuedEventEntity(
      eventId: event.id,
      kind: event.kind,
      content: event.content,
      authorPubkey: event.pubkey,
      sig: event.sig,
      created: DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000),
      hTag: hTag,
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────────────────────

  /// Creates a NIP-29 private group.
  ///
  /// Signs a kind-9002 event. Its [event.id] becomes the [groupId] so the
  /// server can identify the group from the creation event alone. All
  /// subsequent events for this group use `["h", groupId]` tag.
  ///
  /// Returns the generated [groupId] (= event id of the creation event).
  Future<String> createGroup({
    required String privkeyHex, // hex private key for signing
    required String authorPubkey,
    required String name,
    required String description,
    required List<String> relays,
  }) async {
    // 1. Initialize local MLS group state
    final createResult = await _mlsService.createGroup(
      creatorPubkeyHex: authorPubkey,
    );
    final mlsGroupId = base64Encode(createResult.groupId);

    // 2. Sign the group creation event (kind 9002 — NIP-29 edit-metadata).
    //    No `h` tag here: this IS the creation event, and its id becomes the groupId.
    final createdAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final event = Event.from(
      privkey: privkeyHex,
      kind: 9002,
      content: jsonEncode({'name': name, 'about': description}),
      tags: [],
      createdAt: createdAt,
    );

    final groupId = event.id; // ← groupId = event id of the creation event

    // 3. Persist locally + queue for relay
    await _groups.createGroup(
      group: PrivateGroupEntity(
        id: 0, // assigned by the store
        groupId: groupId,
        mlsGroupId: mlsGroupId,
        name: name,
        description: description,
        relays: relays,
        adminPubkey: authorPubkey,
      ),
      event: _buildQueueEntry(event),
    );

    return groupId;
  }

  /// NIP-29 Join Request with MLS KeyPackage embedded in content.
  ///
  /// Saves a local [PrivateGroupModel] stub so [CentralRelayManager] can
  /// route the join event to the correct relays. The stub has an empty
  /// mlsGroupId until the admin sends back the Welcome message.
  Future<void> joinGroup({
    required String groupId,
    required String authorPubkey,
    required String privkeyHex,
    required List<String> relays,
  }) async {
    final keyPackageB64 = await _mlsService.generateKeyPackage(
      pubkeyHex: authorPubkey,
    );

    final event = Event.from(
      privkey: privkeyHex,
      kind: 9021,
      content: keyPackageB64,
      tags: [
        ['h', groupId]
      ],
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );

    // Saves a local stub so the relay router can find the group's relays.
    await _groups.requestJoin(
      groupId: groupId,
      relays: relays,
      event: _buildQueueEntry(event),
    );
  }

  /// NIP-29 Leave Request.
  Future<void> leaveGroup({
    required String groupId,
    required String authorPubkey,
    required String privkeyHex,
  }) async {
    final group = await _findGroup(groupId);

    final event = Event.from(
      privkey: privkeyHex,
      kind: 9022,
      content: '',
      tags: [
        ['h', groupId]
      ],
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );

    if (group != null && group.mlsGroupId.isNotEmpty) {
      try {
        await _mlsService.leaveGroup(
          groupId: group.mlsGroupId,
          groupIdIsBase64: true,
        );
      } catch (_) {
        // Best effort: continue with local row removal + relay leave event queue.
      }
    }

    await _groups.leaveGroup(
      groupId: groupId,
      event: _buildQueueEntry(event),
    );
  }

  /// Encrypts an application message (kind 9023) and queues it.
  ///
  /// [embeddedNoteJson] is the embed-by-value share snapshot, carried inside the
  /// encrypted envelope (key `em`).
  Future<void> sendGroupMessage({
    required String groupId,
    required String content,
    required String authorPubkey,
    required String privkeyHex,
    List<String> mentionRefs = const [],
    String? rootEventId,
    String? replyToEventId,
    String? embeddedNoteJson,
    List<MediaBlobEntity> attachments = const [],
  }) async {
    final group = await _findGroup(groupId);
    if (group == null) {
      throw Exception('Private group not found locally for groupId: $groupId');
    }
    if (group.mlsGroupId.isEmpty) {
      throw Exception('MLS group is not initialized for groupId: $groupId');
    }

    final encryptedPayload = await _mlsService.encryptMessage(
      groupId: group.mlsGroupId,
      content: _encodeMessageEnvelope(
        content,
        mentionRefs,
        rootEventId: rootEventId,
        replyToEventId: replyToEventId,
        embeddedNoteJson: embeddedNoteJson,
        attachments: attachments,
      ),
      groupIdIsBase64: true,
    );

    final now = DateTime.now();
    final event = Event.from(
      privkey: privkeyHex,
      kind: 9023,
      content: encryptedPayload,
      tags: [
        ['h', groupId]
      ],
      createdAt: now.millisecondsSinceEpoch ~/ 1000,
    );

    final localMessage = NoteEntity(
      id: event.id,
      sig: '',
      authorPubkey: authorPubkey,
      content: content,
      kind: kPrivateGroupKind,
      sourcePrivateGroupId: groupId,
      type: attachments.any((a) => a.mime.startsWith('image/'))
          ? NoteType.image
          : NoteType.text,
      eTagRefs: mentionRefs,
      rootEventId: rootEventId,
      replyToEventId: replyToEventId,
      pTagRefs: const [],
      tTags: const [],
      created: now,
      embeddedNoteJson: embeddedNoteJson,
      attachments: attachments,
    );

    await _groups.sendMessage(
      message: localMessage,
      event: _buildQueueEntry(event),
    );
  }

  /// Admin approves a join request: publishes MLS Welcome (9024) + Commit (9025).
  Future<void> approveJoinRequest({
    required String groupId,
    required String userKeyPackageB64,
    required String adminPrivkeyHex,
  }) async {
    final group = await _findGroup(groupId);
    if (group == null) {
      throw Exception('Private group not found locally for groupId: $groupId');
    }
    if (group.mlsGroupId.isEmpty) {
      throw Exception('MLS group is not initialized for groupId: $groupId');
    }

    // A member may tap "request to join" several times, producing multiple
    // join-request rows that all share one persistent MLS signature key.
    // Resolve the requester so every one of their pending rows is cleared on
    // approval — otherwise a leftover row could be approved again and OpenMLS
    // would reject the duplicate signature key.
    final senderPubkey =
        await _groups.senderForKeyPackage(groupId, userKeyPackageB64);

    try {
      final addResult = await _mlsService.addMembers(
        groupId: group.mlsGroupId,
        keyPackagesB64: [userKeyPackageB64],
        groupIdIsBase64: true,
      );

      final welcomeEvent = Event.from(
        privkey: adminPrivkeyHex,
        kind: 9024,
        content: base64Encode(addResult.welcome),
        tags: [
          ['h', groupId]
        ],
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );

      final commitEvent = Event.from(
        privkey: adminPrivkeyHex,
        kind: 9025,
        content: base64Encode(addResult.commit),
        tags: [
          ['h', groupId]
        ],
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );

      await _groups.approveJoinRequests(
        groupId: groupId,
        keyPackageB64: userKeyPackageB64,
        senderPubkey: senderPubkey,
        events: [
          _buildQueueEntry(welcomeEvent),
          _buildQueueEntry(commitEvent),
        ],
      );
    } catch (e) {
      // The member's signature key is already in the group — they were added by
      // a previous commit. Treat as success and mark the stale request(s)
      // handled instead of surfacing "Duplicate signature key" to the admin.
      if (_isAlreadyMemberError(e)) {
        await _groups.approveJoinRequests(
          groupId: groupId,
          keyPackageB64: userKeyPackageB64,
          senderPubkey: senderPubkey,
        );
        return;
      }
      rethrow;
    }
  }

  bool _isAlreadyMemberError(Object error) {
    return error.toString().toLowerCase().contains('duplicate signature key');
  }
}
