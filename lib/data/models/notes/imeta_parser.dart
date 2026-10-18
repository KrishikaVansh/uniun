import 'package:uniun/core/notes/imeta_tag_parser.dart' as core;
import 'package:uniun/data/models/notes/media_attachment.dart';

export 'package:uniun/core/notes/imeta_tag_parser.dart' show ImetaTag;

class ImetaParser {
  ImetaParser._();

  /// See [core.ImetaTagParser.parse].
  static List<core.ImetaTag> parse(Map<String, dynamic> event) =>
      core.ImetaTagParser.parse(event);

  /// Inbound convenience — `parse` followed by mapping each tag to the
  /// embedded [MediaAttachment] that lives on [NoteModel.attachments].
  /// Called once per event by the inbound handlers.
  static List<MediaAttachment> parseAsAttachments(Map<String, dynamic> event) {
    final tags = core.ImetaTagParser.parse(event);
    return [
      for (final t in tags)
        MediaAttachment()
          ..sha256 = t.sha256
          ..mime = t.mime
          ..sizeBytes = t.sizeBytes ?? 0
          ..url = t.url
          ..width = t.width
          ..height = t.height
          ..blurhash = t.blurhash
          ..filename = t.filename,
    ];
  }
}
