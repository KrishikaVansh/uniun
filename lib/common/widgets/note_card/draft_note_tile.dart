import 'package:flutter/material.dart';
import 'package:uniun/common/widgets/markdown/note_markdown_body.dart';
import 'package:uniun/common/widgets/note_card/media_attachment_view.dart';
import 'package:uniun/common/widgets/user_avatar.dart';
import 'package:uniun/core/theme/app_custom_colors.dart';
import 'package:uniun/core/utils/formatters.dart';
import 'package:uniun/domain/entities/media/media_blob_entity.dart';
import 'package:uniun/domain/entities/profile/profile_entity.dart';

/// A draft drawn with the note look (avatar, name, time, text, media, tags)
/// but none of a published note's actions: a draft has no event id yet, so it
/// cannot be saved, shared or reported.
class DraftNoteTile extends StatelessWidget {
  const DraftNoteTile({
    super.key,
    required this.draftId,
    required this.content,
    required this.draftLabel,
    this.authorPubkey,
    this.profile,
    this.created,
    this.attachments = const [],
    this.tTags = const [],
    this.onTap,
  });

  final String draftId;
  final String content;
  final String draftLabel;
  final String? authorPubkey;
  final ProfileEntity? profile;
  final DateTime? created;
  final List<MediaBlobEntity> attachments;
  final List<String> tTags;

  /// Opens the draft's thread. Passed to the markdown body too, because its
  /// selectable text would otherwise swallow a tap on the words.
  final VoidCallback? onTap;

  String _shortName(String pubkey) {
    if (pubkey.length <= 16) return pubkey;
    return '${pubkey.substring(0, 8)}...${pubkey.substring(pubkey.length - 4)}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isEmpty = content.trim().isEmpty;
    final hasMedia = attachments.isNotEmpty;
    final displayName =
        profile?.name ?? profile?.username ?? _shortName(authorPubkey ?? '');

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UserAvatar(
            seed: authorPubkey ?? draftId,
            photoUrl: profile?.avatarUrl,
            size: 40,
            borderRadius: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        displayName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                    if (created != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        formatTimeAgo(created!),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: colorScheme.outline,
                        ),
                      ),
                    ],
                    const SizedBox(width: 8),
                    _DraftChip(label: draftLabel),
                  ],
                ),
                const SizedBox(height: 6),
                if (isEmpty && !hasMedia)
                  Text(
                    '—',
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.55,
                      color: colorScheme.outline.withValues(alpha: 0.6),
                      fontStyle: FontStyle.italic,
                    ),
                  )
                else if (!isEmpty)
                  NoteMarkdownBody(
                    content: content,
                    onTap: onTap,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.55,
                      color: colorScheme.onSurface,
                    ),
                  ),

                // Media staged locally on this device (NIP-92 once published).
                if (hasMedia)
                  MediaAttachmentView.fromBlobs(attachments: attachments),

                if (tTags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: tTags
                        .take(3)
                        .map(
                          (t) => Text(
                            '#$t',
                            style: TextStyle(
                              fontSize: 13,
                              color: colorScheme.primary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small "Draft" pill shown beside the author name so the note-look card still
/// reads as a draft.
class _DraftChip extends StatelessWidget {
  const _DraftChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: context.custom.graphDraft.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: context.custom.graphDraft,
        ),
      ),
    );
  }
}
