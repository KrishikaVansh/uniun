import 'package:dartz/dartz.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/domain/repositories/profile_repository.dart';
import 'package:uniun/features/share/widgets/collapsible_section.dart';
import 'package:uniun/features/share/widgets/destination_tile.dart';
import 'package:uniun/features/share/widgets/dm_destination_tile.dart';
import 'package:uniun/l10n/app_localizations.dart';

import '../../../_helpers/fixtures.dart';

class _MockProfiles extends Mock implements ProfileRepository {}

/// Covers: DestinationTile (icon vs custom leading, subtitle, selected check,
/// tap), CollapsibleSection (collapsed by default, toggling, initially open)
/// and DmDestinationTile (profile name, username, short-pubkey fallback,
/// selected, tap).
void main() {
  Widget host(Widget child) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  group('DestinationTile', () {
    testWidgets('shows the title, the icon and no check by default', (t) async {
      await t.pumpWidget(host(
        DestinationTile(icon: Icons.tag_rounded, title: 'General', onTap: () {}),
      ));

      expect(find.text('General'), findsOneWidget);
      expect(find.byIcon(Icons.tag_rounded), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    });

    testWidgets('shows the subtitle only when given', (t) async {
      await t.pumpWidget(host(
        DestinationTile(
          icon: Icons.tag_rounded,
          title: 'General',
          subtitle: 'नमस्ते 🌍',
          onTap: () {},
        ),
      ));
      expect(find.text('नमस्ते 🌍'), findsOneWidget);

      await t.pumpWidget(host(
        DestinationTile(icon: Icons.tag_rounded, title: 'General', onTap: () {}),
      ));
      expect(find.text('नमस्ते 🌍'), findsNothing);
    });

    testWidgets('a selected tile shows the check', (t) async {
      await t.pumpWidget(host(
        DestinationTile(
          icon: Icons.tag_rounded,
          title: 'General',
          selected: true,
          onTap: () {},
        ),
      ));

      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    });

    testWidgets('a custom leading replaces the icon chip', (t) async {
      await t.pumpWidget(host(
        DestinationTile(
          leading: const Text('LEAD'),
          title: 'Bob',
          onTap: () {},
        ),
      ));

      expect(find.text('LEAD'), findsOneWidget);
    });

    testWidgets('tapping calls onTap', (t) async {
      var taps = 0;
      await t.pumpWidget(host(
        DestinationTile(
          icon: Icons.tag_rounded,
          title: 'General',
          onTap: () => taps++,
        ),
      ));

      await t.tap(find.text('General'));

      expect(taps, 1);
    });
  });

  group('CollapsibleSection', () {
    Widget section({bool open = false}) => host(
      CollapsibleSection(
        label: 'PUBLIC GROUPS',
        initiallyExpanded: open,
        child: const Text('body'),
      ),
    );

    testWidgets('starts collapsed: the body takes no height', (t) async {
      await t.pumpWidget(section());

      expect(find.text('PUBLIC GROUPS'), findsOneWidget);
      expect(t.getSize(find.byType(SizeTransition)).height, lessThan(1));
    });

    testWidgets('tapping the header opens it, tapping again closes it',
        (t) async {
      await t.pumpWidget(section());

      await t.tap(find.text('PUBLIC GROUPS'));
      await t.pumpAndSettle();
      expect(t.getSize(find.byType(SizeTransition)).height, greaterThan(5));

      await t.tap(find.text('PUBLIC GROUPS'));
      await t.pumpAndSettle();
      expect(t.getSize(find.byType(SizeTransition)).height, lessThan(1));
    });

    testWidgets('initiallyExpanded starts open', (t) async {
      await t.pumpWidget(section(open: true));

      expect(t.getSize(find.byType(SizeTransition)).height, greaterThan(5));
    });
  });

  group('DmDestinationTile', () {
    late _MockProfiles profiles;

    setUp(() async {
      profiles = _MockProfiles();
      await GetIt.instance.reset();
      GetIt.instance.registerSingleton<ProfileRepository>(profiles);
    });

    tearDown(() => GetIt.instance.reset());

    Widget tile({bool selected = false, VoidCallback? onTap}) => host(
      DmDestinationTile(
        otherPubkeyHex: kAlicePub,
        selected: selected,
        onTap: onTap ?? () {},
      ),
    );

    testWidgets('shows the peer name once the profile loads', (t) async {
      when(() => profiles.getProfile(kAlicePub)).thenAnswer(
        (_) async => Right(aProfile(pubkey: kAlicePub, name: 'Alice')),
      );

      await t.pumpWidget(tile());
      await t.pump();

      expect(find.text('Alice'), findsOneWidget);
    });

    testWidgets('falls back to the username when there is no name', (t) async {
      when(() => profiles.getProfile(kAlicePub)).thenAnswer(
        (_) async =>
            Right(aProfile(pubkey: kAlicePub, name: null, username: 'ali_u')),
      );

      await t.pumpWidget(tile());
      await t.pump();

      expect(find.text('ali_u'), findsOneWidget);
    });

    testWidgets('shows the short pubkey when the profile is unknown',
        (t) async {
      when(() => profiles.getProfile(kAlicePub)).thenAnswer(
        (_) async => const Left(Failure.notFoundFailure('none')),
      );

      await t.pumpWidget(tile());
      await t.pump();

      expect(find.text('alice-pub'), findsOneWidget);
    });

    testWidgets('selected shows the check and tapping calls onTap', (t) async {
      when(() => profiles.getProfile(any())).thenAnswer(
        (_) async => const Left(Failure.notFoundFailure('none')),
      );
      var taps = 0;

      await t.pumpWidget(tile(selected: true, onTap: () => taps++));
      await t.pump();
      await t.tap(find.byType(DestinationTile));

      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(taps, 1);
    });

    testWidgets('a tile removed before its profile loads does not update',
        (t) async {
      final gate = Future<Either<Failure, dynamic>>.delayed(
        const Duration(milliseconds: 50),
        () => const Left(Failure.notFoundFailure('none')),
      );
      when(() => profiles.getProfile(any())).thenAnswer((_) async {
        await gate;
        return const Left(Failure.notFoundFailure('none'));
      });

      await t.pumpWidget(tile());
      await t.pumpWidget(host(const SizedBox()));
      await t.pump(const Duration(milliseconds: 100));

      expect(t.takeException(), isNull);
    });
  });
}
