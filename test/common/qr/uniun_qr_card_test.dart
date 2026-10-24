import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:uniun/common/qr/uniun_qr_card.dart';
import 'package:uniun/l10n/app_localizations.dart';

/// Covers: the four card factories (caption, avatar/icon, id row), the DM
/// toggle, copy-to-clipboard with its snackbar, the show() sheet, and the share
/// flow (PNG capture, deep link text, failure snackbar, temp-file cleanup).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tmp;
  late List<MethodCall> shared;
  late List<MethodCall> clipboard;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('uniun_qr_card_');
    shared = [];
    clipboard = [];
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getTemporaryDirectory') return tmp.path;
      return null;
    });
    messenger.setMockMethodCallHandler(shareChannel, (call) async {
      shared.add(call);
      return 'dev.fluttercommunity.plus/share/unavailable';
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard.add(call);
      return null;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(shareChannel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Widget host(Widget child) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );

  Future<void> settleShare(WidgetTester t) async {
    for (var i = 0; i < 5; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await t.pump();
    }
  }

  group('factories', () {
    testWidgets('user card shows the name, the full npub and its caption', (
      t,
    ) async {
      await t.pumpWidget(
        host(UniunQrCard.user(npub: 'npub1alice', name: 'Alice')),
      );

      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('npub1alice'), findsOneWidget);
      expect(find.text('Scan this to add you on UNIUN.'), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
    });

    testWidgets('a nameless user card falls back to "User"', (t) async {
      await t.pumpWidget(host(UniunQrCard.user(npub: 'npub1x')));

      expect(find.text('User'), findsOneWidget);
    });

    testWidgets('public group card shows the tag icon and its caption', (
      t,
    ) async {
      await t.pumpWidget(
        host(
          UniunQrCard.publicGroup(
            name: 'नमस्ते 🌍',
            groupId: 'gid1',
            relays: const ['wss://r.example'],
          ),
        ),
      );

      expect(find.text('नमस्ते 🌍'), findsOneWidget);
      expect(find.byIcon(Icons.tag_rounded), findsOneWidget);
      expect(find.text('Scan to join this group.'), findsOneWidget);
    });

    testWidgets('private group card shows the lock icon and its caption', (
      t,
    ) async {
      await t.pumpWidget(
        host(
          UniunQrCard.privateGroup(
            name: 'Secret',
            groupId: 'pgid1',
            relays: const [],
          ),
        ),
      );

      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.text('Scan to join this private group.'), findsOneWidget);
    });

    testWidgets('a single-entry card has no toggle', (t) async {
      await t.pumpWidget(host(UniunQrCard.user(npub: 'npub1a', name: 'A')));

      expect(find.text('Their key'), findsNothing);
      expect(find.text('My key'), findsNothing);
    });
  });

  group('DM card toggle', () {
    Widget dm() => host(
      UniunQrCard.dmConversation(
        partnerNpub: 'npub1partner',
        partnerName: 'Pat',
        myNpub: 'npub1me',
      ),
    );

    testWidgets('opens on the partner key and switches to mine', (t) async {
      await t.pumpWidget(dm());

      expect(find.text('Their key'), findsOneWidget);
      expect(find.text('My key'), findsOneWidget);
      expect(find.text('npub1partner'), findsOneWidget);
      expect(find.text('Scan to start a chat on UNIUN.'), findsOneWidget);

      await t.tap(find.text('My key'));
      await t.pumpAndSettle();

      expect(find.text('npub1me'), findsOneWidget);
      expect(find.text('npub1partner'), findsNothing);
      // No own name was given, so the label falls back.
      expect(find.text('Your key'), findsOneWidget);

      await t.tap(find.text('Their key'));
      await t.pumpAndSettle();
      expect(find.text('npub1partner'), findsOneWidget);
    });
  });

  group('copy', () {
    testWidgets('copies the full id and confirms with a snackbar', (t) async {
      await t.pumpWidget(
        host(
          UniunQrCard.publicGroup(
            name: 'G',
            groupId: 'a-very-long-group-id-0123456789',
            relays: const [],
          ),
        ),
      );

      await t.tap(find.byIcon(Icons.copy_rounded));
      await t.pump();

      expect(clipboard, hasLength(1));
      expect(
        (clipboard.single.arguments as Map)['text'],
        'a-very-long-group-id-0123456789',
      );
      expect(find.text('Copy group ID • copied to clipboard'), findsOneWidget);
    });

    testWidgets('a user card copies the npub', (t) async {
      await t.pumpWidget(host(UniunQrCard.user(npub: 'npub1zzz', name: 'Z')));

      await t.tap(find.byIcon(Icons.copy_rounded));
      await t.pump();

      expect((clipboard.single.arguments as Map)['text'], 'npub1zzz');
      expect(find.text('Copy npub • copied to clipboard'), findsOneWidget);
    });
  });

  group('show', () {
    testWidgets('presents the card as a modal bottom sheet', (t) async {
      await t.pumpWidget(
        host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => UniunQrCard.show(
                context,
                card: UniunQrCard.user(npub: 'npub1sheet', name: 'Sheet'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );

      await t.tap(find.text('open'));
      await t.pumpAndSettle();

      expect(find.byType(UniunQrCard), findsOneWidget);
      expect(find.text('Sheet'), findsOneWidget);
    });
  });

  group('share', () {
    testWidgets('shares the QR image with the user deep link', (t) async {
      await t.pumpWidget(
        host(UniunQrCard.user(npub: 'npub1share', name: 'Sam')),
      );

      await t.tap(find.text('Share'));
      await settleShare(t);

      expect(shared, hasLength(1));
      final args = shared.single.arguments as Map;
      expect(args['text'] as String, contains('uniun.in'));
      expect(args['text'] as String, contains('npub1share'));
      expect(args['paths'] as List, hasLength(1));
      // The temp PNG is removed once the share sheet has taken it.
      expect(File('${tmp.path}/uniun_qr_share.png').existsSync(), isFalse);
    });

    testWidgets('a public group shares its group link', (t) async {
      await t.pumpWidget(
        host(
          UniunQrCard.publicGroup(
            name: 'Dev',
            groupId: 'gidpub',
            relays: const ['wss://r.example'],
          ),
        ),
      );

      await t.tap(find.text('Share'));
      await settleShare(t);

      expect((shared.single.arguments as Map)['text'], contains('gidpub'));
    });

    testWidgets('a private group shares its private link', (t) async {
      await t.pumpWidget(
        host(
          UniunQrCard.privateGroup(
            name: 'Priv',
            groupId: 'gidpriv',
            relays: const [],
          ),
        ),
      );

      await t.tap(find.text('Share'));
      await settleShare(t);

      expect((shared.single.arguments as Map)['text'], contains('gidpriv'));
    });

    testWidgets('a failure shows the failed snackbar and shares nothing', (
      t,
    ) async {
      messenger.setMockMethodCallHandler(pathChannel, (call) async {
        throw PlatformException(code: 'no-dir');
      });
      await t.pumpWidget(host(UniunQrCard.user(npub: 'npub1f', name: 'F')));

      await t.tap(find.text('Share'));
      await settleShare(t);

      expect(shared, isEmpty);
      expect(find.text("Couldn't share QR code"), findsOneWidget);
    });
  });
}
