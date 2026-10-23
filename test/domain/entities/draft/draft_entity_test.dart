import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/core/enum/note_type.dart';
import 'package:uniun/domain/entities/draft/draft_entity.dart';

import '../../../_helpers/fixtures.dart';

/// Covers: DraftAsNote.toNoteEntity — the draft shaped as a note for the
/// thread screen (draft uuid as id, no signature, type from attachments).
void main() {
  test('carries the draft fields, uses the uuid as id and has no signature',
      () {
    final note = aDraft(
      draftId: 'uuid-1',
      content: 'नमस्ते 🌍 #plans',
      rootEventId: 'root',
      replyToEventId: 'parent',
      eTagRefs: ['root', 'parent', 'm1'],
      tTags: ['plans'],
    ).toNoteEntity(authorPubkey: kSelfPub);

    expect(note.id, 'uuid-1');
    expect(note.sig, isEmpty);
    expect(note.authorPubkey, kSelfPub);
    expect(note.content, 'नमस्ते 🌍 #plans');
    expect(note.rootEventId, 'root');
    expect(note.replyToEventId, 'parent');
    expect(note.eTagRefs, ['root', 'parent', 'm1']);
    expect(note.tTags, ['plans']);
    expect(note.created, tT0);
    expect(note.type, NoteType.text);
  });

  test('an image attachment makes it an image note, others stay text', () {
    expect(
      aDraft(attachments: [aMediaBlob(mime: 'image/png')])
          .toNoteEntity(authorPubkey: kSelfPub)
          .type,
      NoteType.image,
    );
    expect(
      aDraft(attachments: [aMediaBlob(mime: 'application/pdf')])
          .toNoteEntity(authorPubkey: kSelfPub)
          .type,
      NoteType.text,
    );
  });

  test('the attachments ride along for rendering', () {
    final note = aDraft(attachments: [aMediaBlob(sha256: 's1')])
        .toNoteEntity(authorPubkey: kSelfPub);

    expect(note.attachments.single.sha256, 's1');
    expect(note.hasMedia, isTrue);
  });
}
