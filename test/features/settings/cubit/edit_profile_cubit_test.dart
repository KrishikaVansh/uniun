import 'package:dartz/dartz.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/domain/entities/profile/profile_entity.dart';
import 'package:uniun/domain/usecases/profile_usecases.dart';
import 'package:uniun/domain/usecases/user_usecases.dart';
import 'package:uniun/features/settings/cubit/edit_profile_cubit.dart';

import '../../../_helpers/fixtures.dart';

class _MockUser extends Mock implements GetActiveUserUseCase {}

class _MockOwn extends Mock implements GetOwnProfileUseCase {}

class _MockSave extends Mock implements SaveProfileUseCase {}

class _MockPublish extends Mock implements PublishProfileMetadataUseCase {}

/// Covers: EditProfileCubit loading the saved profile, the fields, saving with
/// blanks turned into null, and each way saving or publishing can fail.
void main() {
  late _MockUser user;
  late _MockOwn own;
  late _MockSave save;
  late _MockPublish publish;

  setUpAll(() => registerFallbackValue(aProfile()));

  setUp(() {
    user = _MockUser();
    own = _MockOwn();
    save = _MockSave();
    publish = _MockPublish();
    when(() => user.call()).thenAnswer((_) async => Right(aUserKey()));
    when(() => own.call(any())).thenAnswer(
      (_) async => Right(
        aProfile(
          pubkey: kSelfPub,
          name: 'Asha',
          username: 'asha',
          about: 'about me',
          avatarUrl: 'https://img/x.png',
          nip05: 'asha@uniun.in',
        ),
      ),
    );
    when(() => save.call(any())).thenAnswer(
      (i) async => Right(i.positionalArguments.first as ProfileEntity),
    );
    when(() => publish.call(any())).thenAnswer((_) async => const Right(unit));
  });

  EditProfileCubit build() => EditProfileCubit(user, own, save, publish);

  Future<EditProfileCubit> loaded() async {
    final c = build();
    await pumpEventQueue();
    return c;
  }

  test('starts loading, then fills the form from the saved profile', () async {
    final c = build();
    expect(c.state.status, EditProfileStatus.loading);

    await pumpEventQueue();

    expect(c.state.status, EditProfileStatus.initial);
    expect(c.state.pubkeyHex, kSelfPub);
    expect(c.state.name, 'Asha');
    expect(c.state.username, 'asha');
    expect(c.state.about, 'about me');
    expect(c.state.avatarUrl, 'https://img/x.png');
    expect(c.state.nip05, 'asha@uniun.in');
    await c.close();
  });

  test('a user with no saved profile gets an empty form', () async {
    when(() => own.call(any())).thenAnswer((_) async => const Right(null));

    final c = await loaded();

    expect(c.state.status, EditProfileStatus.initial);
    expect(c.state.name, isEmpty);
    expect(c.state.pubkeyHex, kSelfPub);
    await c.close();
  });

  test('no active user is an error and nothing else is read', () async {
    when(
      () => user.call(),
    ).thenAnswer((_) async => const Left(Failure.errorFailure('none')));

    final c = await loaded();

    expect(c.state.status, EditProfileStatus.error);
    expect(c.state.error, 'No active user');
    verifyNever(() => own.call(any()));
    await c.close();
  });

  test('a throwing load is reported, not crashed', () async {
    when(() => own.call(any())).thenThrow(StateError('boom'));

    final c = await loaded();

    expect(c.state.status, EditProfileStatus.error);
    expect(c.state.error, contains('boom'));
    await c.close();
  });

  test('each field updates the state', () async {
    final c = await loaded();

    c
      ..updateName('N')
      ..updateUsername('U')
      ..updateAbout('A')
      ..updateAvatarUrl('V')
      ..updateNip05('P');

    expect(
      (
        c.state.name,
        c.state.username,
        c.state.about,
        c.state.avatarUrl,
        c.state.nip05,
      ),
      ('N', 'U', 'A', 'V', 'P'),
    );
    await c.close();
  });

  test(
    'save trims the text, turns blanks into null, saves and publishes',
    () async {
      final c = await loaded();
      c
        ..updateName('  Asha K  ')
        ..updateUsername('   ')
        ..updateAbout('')
        ..updateAvatarUrl(' https://img/y.png ')
        ..updateNip05('  ');

      final ok = await c.save();

      expect(ok, isTrue);
      expect(c.state.status, EditProfileStatus.saved);
      final saved =
          verify(() => save.call(captureAny())).captured.single
              as ProfileEntity;
      expect(saved.name, 'Asha K');
      expect(saved.username, isNull);
      expect(saved.about, isNull);
      expect(saved.avatarUrl, 'https://img/y.png');
      expect(saved.nip05, isNull);
      expect(saved.lastSeenAt, DateTime(3000, 6, 1));
      verify(() => publish.call(any())).called(1);
      await c.close();
    },
  );

  test('unicode and emoji survive a save untouched', () async {
    final c = await loaded();
    c.updateName('アーシャ 🌸 आशा');

    await c.save();

    final saved =
        verify(() => save.call(captureAny())).captured.single as ProfileEntity;
    expect(saved.name, 'アーシャ 🌸 आशा');
    await c.close();
  });

  test('save with no identity loaded does nothing', () async {
    when(
      () => user.call(),
    ).thenAnswer((_) async => const Left(Failure.errorFailure('none')));
    final c = await loaded();

    final ok = await c.save();

    expect(ok, isFalse);
    verifyNever(() => save.call(any()));
    await c.close();
  });

  test('a failed save shows its message and does not publish', () async {
    when(
      () => save.call(any()),
    ).thenAnswer((_) async => const Left(Failure.errorFailure('disk full')));
    final c = await loaded();

    final ok = await c.save();

    expect(ok, isFalse);
    expect(c.state.status, EditProfileStatus.error);
    expect(c.state.error, isNotNull);
    verifyNever(() => publish.call(any()));
    await c.close();
  });

  test(
    'a failed publish is an error even though it was saved locally',
    () async {
      when(
        () => publish.call(any()),
      ).thenAnswer((_) async => const Left(Failure.errorFailure('no relay')));
      final c = await loaded();

      final ok = await c.save();

      expect(ok, isFalse);
      expect(c.state.status, EditProfileStatus.error);
      verify(() => save.call(any())).called(1);
      await c.close();
    },
  );

  test('a throwing save is reported', () async {
    when(() => save.call(any())).thenThrow(StateError('crash'));
    final c = await loaded();

    final ok = await c.save();

    expect(ok, isFalse);
    expect(c.state.status, EditProfileStatus.error);
    expect(c.state.error, contains('crash'));
    await c.close();
  });
}
