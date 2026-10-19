import 'package:dartz/dartz.dart';
import 'package:injectable/injectable.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/core/utils/pubkey_normalizer.dart';
import 'package:uniun/data/models/dm/dm_conversation_model.dart';
import 'package:uniun/domain/entities/dm/dm_conversation_entity.dart';
import 'package:uniun/domain/repositories/dm_conversation_repository.dart';
import 'package:uniun/features/mesh/sync/bodies/dm_conversation_body.dart';
import 'package:uniun/features/mesh/sync/mesh_event_codec.dart';
import 'package:uniun/features/mesh/sync/mesh_event_signer.dart';

@Injectable(as: DmConversationRepository)
class DmConversationRepositoryImpl extends DmConversationRepository {
  final Isar isar;
  final MeshEventSigner _signer;
  DmConversationRepositoryImpl({
    required this.isar,
    required MeshEventSigner signer,
  }) : _signer = signer;

  @override
  Future<Either<Failure, List<DmConversationEntity>>> getConversations() async {
    try {
      final rows = await isar.dmConversationModels
          .filter()
          .removedAtIsNull()
          .findAll();
      rows.sort((a, b) => a.otherPubkey.compareTo(b.otherPubkey));
      return Right(rows.map((c) => c.toDomain()).toList());
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, DmConversationEntity>> getConversationByOtherPubkey(
    String otherPubkey,
  ) async {
    try {
      final normalizedPubkey = normalizeNostrPubkey(otherPubkey);
      final row = await isar.dmConversationModels
          .filter()
          .otherPubkeyEqualTo(normalizedPubkey)
          .removedAtIsNull()
          .findFirst();
      if (row == null) {
        return Left(
          Failure.notFoundFailure(
            'DM conversation not found for otherPubkey: $normalizedPubkey',
          ),
        );
      }
      return Right(row.toDomain());
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, DmConversationEntity>> saveConversation(
    DmConversationEntity entity,
  ) async {
    try {
      final normalizedPubkey = normalizeNostrPubkey(entity.otherPubkey);
      // Reactivate an existing tombstone rather than short-circuit — the user
      // starting a new DM with the same counterparty means "restore".
      final existing = await isar.dmConversationModels
          .where()
          .otherPubkeyEqualTo(normalizedPubkey)
          .findFirst();
      if (existing != null && existing.removedAt == null) {
        return Right(existing.toDomain());
      }

      final model = (existing ?? DmConversationModel())
        ..otherPubkey = normalizedPubkey
        ..relays = entity.relays
        ..removedAt = null;

      model.signedNostrEvent = await _signer.sign(
        kind: MeshEventKinds.dmConversation,
        dTag: normalizedPubkey,
        content: DmConversationBody.forActive(model),
      );

      await isar.writeTxn(() async {
        await isar.dmConversationModels.put(model);
      });
      return Right(model.toDomain());
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, DmConversationEntity>> ensureActive(
    String otherPubkey,
  ) async {
    try {
      var conv = await isar.dmConversationModels
          .where()
          .otherPubkeyEqualTo(otherPubkey)
          .findFirst();
      if (conv == null || conv.removedAt != null) {
        conv = (conv ?? DmConversationModel())
          ..otherPubkey = otherPubkey
          ..removedAt = null;
        try {
          final signed = await _signer.sign(
            kind: MeshEventKinds.dmConversation,
            dTag: otherPubkey,
            content: DmConversationBody.forActive(conv),
          );
          if (signed != null) conv.signedNostrEvent = signed;
        } catch (_) {
          // Non-fatal: the row still lands; the mesh migration pass backfills
          // `signedNostrEvent` on the next launch.
        }
        final row = conv;
        await isar.writeTxn(() async {
          await isar.dmConversationModels.put(row);
        });
      }
      return Right(conv.toDomain());
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }

  @override
  Future<Either<Failure, Unit>> deleteConversation(String otherPubkey) async {
    try {
      final normalizedPubkey = normalizeNostrPubkey(otherPubkey);
      final existing = await isar.dmConversationModels
          .where()
          .otherPubkeyEqualTo(normalizedPubkey)
          .findFirst();
      if (existing == null || existing.removedAt != null) {
        return const Right(unit);
      }

      // Undo semantics per plan §5a: tombstone instead of deleting so
      // negentropy still surfaces the state flip to peers.
      existing.removedAt = DateTime.now();
      existing.signedNostrEvent = await _signer.sign(
        kind: MeshEventKinds.dmConversation,
        dTag: normalizedPubkey,
        content: DmConversationBody.forRemoved(existing),
      );

      await isar.writeTxn(() async {
        await isar.dmConversationModels.put(existing);
      });
      return const Right(unit);
    } catch (e) {
      return Left(Failure.errorFailure(e.toString()));
    }
  }
}
