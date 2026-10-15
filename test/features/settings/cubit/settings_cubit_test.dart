import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/domain/usecases/profile_usecases.dart';
import 'package:uniun/domain/usecases/user_usecases.dart';
import 'package:uniun/features/settings/cubit/settings_cubit.dart';

import '../../../_helpers/fixtures.dart';

class _MockUser extends Mock implements GetActiveUserUseCase {}

class _MockOwn extends Mock implements GetOwnProfileUseCase {}

/// Covers: SettingsCubit loading the identity and profile, name fallbacks,
/// the short handle, the two toggles and revealing / hiding the nsec.
void main() {
  late _MockUser user;
  late _MockOwn own;

  setUp(() {
    user = _MockUser();
    own = _MockOwn();
    when(() => user.call()).thenAnswer((_) async => Right(aUserKey()));
    when(() => own.call(any())).thenAnswer(
      (_) async =>
          Right(aProfile(pubkey: kSelfPub, name: 'Asha', avatarUrl: 'u')),
    );
  });

  Future<SettingsCubit> loaded() async {
    final c = SettingsCubit(user, own);
    await pumpEventQueue();
    return c;
  }

  test('loads the name, a shortened handle and the avatar', () async {
    final long = 'npub1${'q' * 40}';
    when(
      () => user.call(),
    ).thenAnswer((_) async => Right(aUserKey(npub: long)));
    final c = await loaded();

    expect(c.state.isLoading, isFalse);
    expect(c.state.userName, 'Asha');
    expect(c.state.npub, long);
    expect(c.state.handle, endsWith('...'));
    expect(c.state.handle!.length, 19);
    expect(c.state.pubkeyHex, kSelfPub);
    expect(c.state.avatarUrl, 'u');
    expect(c.state.nsec, isNull);
    await c.close();
  });

  test('a short npub is shown whole', () async {
    when(
      () => user.call(),
    ).thenAnswer((_) async => Right(aUserKey(npub: 'npub1short')));

    final c = await loaded();

    expect(c.state.handle, 'npub1short');
    await c.close();
  });

  test('falls back to the username, then to Anonymous', () async {
    when(() => own.call(any())).thenAnswer(
      (_) async =>
          Right(aProfile(pubkey: kSelfPub, name: null, username: 'asha_k')),
    );
    var c = await loaded();
    expect(c.state.userName, 'asha_k');
    await c.close();

    when(
      () => own.call(any()),
    ).thenAnswer((_) async => Right(aProfile(pubkey: kSelfPub, name: null)));
    c = await loaded();
    expect(c.state.userName, 'Anonymous');
    await c.close();
  });

  test('no saved profile still loads with Anonymous', () async {
    when(
      () => own.call(any()),
    ).thenAnswer((_) async => const Left(Failure.errorFailure('none')));

    final c = await loaded();

    expect(c.state.userName, 'Anonymous');
    expect(c.state.isLoading, isFalse);
    await c.close();
  });

  test('no active user is an error', () async {
    when(
      () => user.call(),
    ).thenAnswer((_) async => const Left(Failure.errorFailure('none')));

    final c = await loaded();

    expect(c.state.isLoading, isFalse);
    expect(c.state.error, 'No active user');
    await c.close();
  });

  test('a throwing load is reported', () async {
    when(() => user.call()).thenThrow(StateError('boom'));

    final c = await loaded();

    expect(c.state.isLoading, isFalse);
    expect(c.state.error, contains('boom'));
    await c.close();
  });

  test('the two notification toggles update the state', () async {
    final c = await loaded();
    expect(c.state.dmNotifications, isTrue);
    expect(c.state.groupAlerts, isFalse);

    c
      ..toggleDmNotifications(false)
      ..toggleGroupAlerts(true);

    expect(c.state.dmNotifications, isFalse);
    expect(c.state.groupAlerts, isTrue);
    await c.close();
  });

  test('revealing the nsec shows it, and a second call hides it', () async {
    final c = await loaded();

    await c.revealNsec();
    expect(c.state.nsecVisible, isTrue);
    expect(c.state.nsec, 'nsec1$kSelfPub');

    await c.revealNsec();
    expect(c.state.nsecVisible, isFalse);
    await c.close();
  });

  test(
    'revealing when the key cannot be read still toggles visibility',
    () async {
      final c = await loaded();
      when(() => user.call()).thenThrow(StateError('keystore'));

      await c.revealNsec();

      expect(c.state.nsecVisible, isTrue);
      expect(c.state.nsec, isNull);
      await c.close();
    },
  );
}
