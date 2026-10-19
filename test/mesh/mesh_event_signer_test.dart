import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nostr_core_dart/nostr.dart';
import 'package:uniun/features/mesh/sync/mesh_event_codec.dart';
import 'package:uniun/features/mesh/sync/mesh_event_signer.dart';

import '../_helpers/fixtures.dart';
import '../_helpers/stub_user_repository.dart';

/// Covers: MeshEventSigner resolving keys per call from the user repository,
/// and the fixed-identity variant the gateway isolate uses.
void main() {
  final pub = Keychain(kTestPrivHex).public;

  Future<String?> sign(MeshEventSigner s) => s.sign(
        kind: MeshEventKinds.dmConversation,
        dTag: 'peer',
        content: {'state': 'active'},
      );

  test('signs with the identity the user repository holds right now',
      () async {
    final users = StubUserRepository()
      ..keys = (privkeyHex: kTestPrivHex, pubkeyHex: pub);
    final signer = MeshEventSigner(users);

    final signed = jsonDecode((await sign(signer))!) as Map<String, dynamic>;
    expect(signed['pubkey'], pub);

    users.keys = null;
    expect(await sign(signer), isNull);
    expect(await signer.currentCodec(), isNull);
  });

  test('the fixed signer needs no user repository and keeps its identity',
      () async {
    final signer = MeshEventSigner.fixed(privkeyHex: kTestPrivHex, pubkeyHex: pub);

    final codec = await signer.currentCodec();
    expect(codec!.pubkeyHex, pub);
    final signed = jsonDecode((await sign(signer))!) as Map<String, dynamic>;
    expect(signed['pubkey'], pub);
    expect(signed['kind'], MeshEventKinds.dmConversation);
  });
}
