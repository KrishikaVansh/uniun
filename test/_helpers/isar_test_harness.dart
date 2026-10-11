import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math' as math;

import 'package:isar_community/isar.dart';
import 'package:uniun/data/datasources/isar_schemas.dart';
import 'package:uniun/data/models/group_model.dart';
import 'package:uniun/data/models/followed_note_model.dart';
import 'package:uniun/data/models/followed_user_model.dart';
import 'package:uniun/data/models/private_group_model.dart';

final math.Random _rng = math.Random();

Future<void>? _coreReady;

/// Downloads the IsarCore native binary once to a stable shared path and
/// hands Isar the explicit library path.
///
/// `Isar.initializeIsarCore(download: true)` is unusable under a parallel
/// `flutter test` run: (a) any suite that initializes
/// `TestWidgetsFlutterBinding` gets flutter_test's mocked `HttpClient`
/// (every request → 400), so the internal download can never succeed there;
/// (b) concurrent suites race on the same un-synchronized target file. Its
/// own docs say "always use `flutter test -j 1`" — this helper removes that
/// restriction by downloading with a real `HttpClient` (zone override
/// escapes the mock) into a temp file that is atomically renamed into place,
/// so concurrent isolates/shards are all safe at any --concurrency.
Future<void> ensureIsarCore() => _coreReady ??= () async {
      // Mobile builds bundle IsarCore with the app's native libraries.
      if (Platform.isAndroid || Platform.isIOS) return;
      final localName = Platform.isMacOS
          ? 'libisar.dylib'
          : Platform.isWindows
              ? 'libisar.dll'
              : 'libisar.so';
      final lib = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'isar_core_${Isar.version}${Platform.pathSeparator}$localName');
      if (!lib.existsSync()) {
        final remoteName = Platform.isMacOS
            ? 'libisar_macos.dylib'
            : Platform.isWindows
                ? 'isar_windows_x64.dll'
                : 'libisar_linux_x64.so';
        await lib.parent.create(recursive: true);
        final tmp = File(
            '${lib.path}.${_rng.nextInt(1 << 32).toRadixString(16)}.part');
        await HttpOverrides.runWithHttpOverrides(() async {
          final client = HttpClient();
          try {
            final req = await client.getUrl(Uri.parse(
                'https://binaries.isar-community.dev/'
                '${Isar.version}/$remoteName'));
            final res = await req.close();
            if (res.statusCode != 200) {
              throw StateError(
                  'IsarCore download failed: HTTP ${res.statusCode}');
            }
            await res.pipe(tmp.openWrite());
          } finally {
            client.close();
          }
        }, _RealHttpOverrides());
        try {
          tmp.renameSync(lib.path);
        } on FileSystemException {
          // Lost the rename race to a parallel isolate — its copy is
          // identical, ours is redundant.
          if (tmp.existsSync()) tmp.deleteSync();
        }
      }
      await Isar.initializeIsarCore(libraries: {Abi.current(): lib.path});
    }();

/// Default [HttpOverrides] — base-class methods create REAL clients,
/// sidestepping flutter_test's global 400-mock inside the zone.
class _RealHttpOverrides extends HttpOverrides {}

/// Opens an isolated on-disk Isar registered with the app's full schema list.
///
/// The instance name is salted with the current microsecond timestamp plus a
/// random suffix so parallel tests (and re-runs after a flaky teardown) never
/// share a name with a still-finalizing Isar — previously a single integer
/// counter was reused across runs, which segfaulted Isar's native finalizer
/// when a slow `deleteFromDisk` overlapped a fresh open at the same name.
///
/// Caller must `close(deleteFromDisk: true)` in `tearDown`.
Future<Isar> openTestIsar() async {
  await ensureIsarCore();
  final dir = await Directory.systemTemp.createTemp('uniun_sub_test');
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final salt = _rng.nextInt(1 << 32).toRadixString(16);
  return Isar.open(
    isarSchemas,
    directory: dir.path,
    name: 'sub_test_${stamp}_$salt',
  );
}

GroupModel groupSeed(
  String groupId, {
  String creatorPubKey = 'creator',
  String name = 'name',
  String about = 'about',
  List<String> relays = const [],
  int createdAt = 0,
  int updatedAt = 0,
  String? lastMetaEvent,
  String? signedNostrEvent,
  DateTime? removedAt,
}) =>
    GroupModel()
      ..groupId = groupId
      ..creatorPubKey = creatorPubKey
      ..name = name
      ..about = about
      ..picture = ''
      ..relays = relays
      ..createdAt = createdAt
      ..updatedAt = updatedAt
      ..lastMetaEvent = lastMetaEvent
      ..signedNostrEvent = signedNostrEvent
      ..removedAt = removedAt;

PrivateGroupModel privateGroupSeed(String groupId) => PrivateGroupModel()
  ..groupId = groupId
  ..mlsGroupId = 'mls_$groupId'
  ..relays = const []
  ..name = 'name'
  ..description = 'desc'
  ..adminPubkey = 'admin';

FollowedUserModel followedUserSeed(String pubkeyHex) => FollowedUserModel()
  ..pubkeyHex = pubkeyHex
  ..followedAt = DateTime(2026, 1, 1);

FollowedNoteModel followedNoteSeed(String eventId) => FollowedNoteModel()
  ..eventId = eventId
  ..contentPreview = 'preview'
  ..followedAt = DateTime(2026, 1, 1);
