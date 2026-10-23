import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:uniun/core/enum/note_type.dart';
import 'package:uniun/domain/entities/media/media_blob_entity.dart';
import 'package:uniun/domain/entities/note/note_entity.dart';

part 'draft_entity.freezed.dart';

@freezed
abstract class DraftEntity with _$DraftEntity {
  const factory DraftEntity({
    required String draftId,
    required String content,
    String? rootEventId,
    String? replyToEventId,
    required List<String> eTagRefs,
    required List<String> pTagRefs,
    required List<String> tTags,
    required DateTime createdAt,
    required DateTime updatedAt,

    /// References to OTHER drafts (by `draftId` UUID). Held separately from
    /// [eTagRefs] (which only carries real event ids). Synced cross-device via
    /// NIP-37 inner-event `["d-ref", uuid]` tags so the same UUIDs resolve on
    /// every device. Dropped or rewritten to event ids at publish time.
    @Default(<String>[]) List<String> draftRefIds,

    /// Non-null once this draft has been published. The row becomes a brief
    /// tombstone carrying the UUID→event-id mapping so referencing drafts
    /// (on this and other devices) can resolve their [draftRefIds].
    String? publishedAsEventId,

    /// Media attached to the draft. Staged **locally only** (bytes live in the
    /// shared media cache, keyed by sha256) — NOT uploaded to Blossom while a
    /// draft. `localPath` is patched in from the cache on read so the draft
    /// renders like any note; `serverUrls` stays empty until the draft is
    /// published, at which point the bytes are uploaded and `imeta` is built.
    @Default(<MediaBlobEntity>[]) List<MediaBlobEntity> attachments,
  }) = _DraftEntity;
}

extension DraftAsNote on DraftEntity {
  /// The draft shaped as a note so the thread screen can render it. Its id is
  /// the draft UUID, not a Nostr event id, and it has no signature.
  NoteEntity toNoteEntity({required String authorPubkey}) => NoteEntity(
        id: draftId,
        sig: '',
        authorPubkey: authorPubkey,
        content: content,
        type: attachments.any((a) => a.mime.startsWith('image/'))
            ? NoteType.image
            : NoteType.text,
        eTagRefs: eTagRefs,
        pTagRefs: pTagRefs,
        tTags: tTags,
        created: createdAt,
        rootEventId: rootEventId,
        replyToEventId: replyToEventId,
        attachments: attachments,
      );
}
