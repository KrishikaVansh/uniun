import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_edge_ai_embeddings/flutter_edge_ai_embeddings.dart' show GemmaEmbeddingTokenizers;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_mediapipe/flutter_edge_ai_mediapipe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:isar_community/isar.dart';
import 'package:uniun/common/locator.dart';
import 'package:uniun/common/atoms/uniun_back_button.dart';
import 'package:uniun/core/router/app_routes.dart';
import 'package:uniun/core/enum/gana_output_type.dart';
import 'package:uniun/core/enum/gana_run_status.dart';
import 'package:uniun/core/enum/gana_trigger_mode.dart';
import 'package:uniun/core/enum/gana_input_type.dart';
import 'package:uniun/core/notes/note_kinds.dart';
import 'package:uniun/core/theme/app_theme.dart';
import 'package:uniun/data/models/gana_model.dart';
import 'package:uniun/core/enum/note_type.dart';
import 'package:uniun/data/models/gana_run_model.dart';
import 'package:uniun/data/models/draft_model.dart';
import 'package:uniun/data/models/manas_model.dart';
import 'package:uniun/data/models/manas_note_link_model.dart';
import 'package:uniun/data/models/notes/note_model.dart';
import 'package:uniun/data/models/saved_note_model.dart';
import 'package:uniun/domain/entities/user_key/user_key_entity.dart';
import 'package:uniun/domain/repositories/user_repository.dart';
import 'package:uniun/domain/usecases/gana_usecases.dart';
import 'package:uniun/domain/usecases/manas_usecases.dart';
import 'package:uniun/features/brahma/manas/pages/manas_form_page.dart';
import 'package:uniun/features/shiv/gana/detail/pages/gana_detail_page.dart';
import 'package:uniun/features/shiv/gana/dashboard/pages/gana_dashboard_page.dart';
import 'package:uniun/features/shiv/gana/form/pages/gana_form_page.dart';
import 'package:uniun/features/shiv/gana/form/bloc/gana_form_bloc.dart';
import 'package:uniun/features/shiv/gana/engine/gana_input_filter.dart';
import 'package:uniun/features/shiv/generation/context/manas_context_loader.dart';
import 'package:uniun/features/shiv/generation/gana_run.dart';
import 'package:uniun/l10n/app_localizations.dart';

import '../test/_helpers/fixtures.dart';

const _holdSeconds = int.fromEnvironment('HOLD_SECONDS');

/// Covers Gana scope selection, Manas creation, draft retention, and run views.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late Isar isar;
  late UserRepository users;
  UserKeyEntity? previousUser;
  late UserKeyEntity testUser;

  setUpAll(() async {
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [LiteRtLmEngine(), MediaPipeEngine()],
      embeddingBackends: const [LiteRtEmbeddingBackend()],
      embeddingTokenizers: const [GemmaEmbeddingTokenizers()],
    );
    if (!getIt.isRegistered<Isar>()) await configureDependencies();
    isar = getIt<Isar>();
    users = getIt<UserRepository>();
    previousUser = (await users.getActiveUser()).fold<UserKeyEntity?>(
      (_) => null,
      (u) => u,
    );
    testUser = (await users.importKey(kTestPrivHex)).getOrElse(
      () => throw StateError('Could not activate the shared test identity'),
    );
  });

  tearDownAll(() async {
    if (previousUser != null && previousUser!.pubkeyHex != testUser.pubkeyHex) {
      final restored = await users.importKey(previousUser!.nsec);
      expect(restored.isRight(), isTrue);
    }
  });

  GoRouter ganaRouter() => GoRouter(
    initialLocation: '/dashboard',
    routes: [
      GoRoute(
        path: '/dashboard',
        builder: (_, __) => const GanaDashboardPage(),
      ),
      GoRoute(
        name: AppRoutes.shivGanaForm,
        path: '/gana/form',
        builder: (_, state) {
          final args = state.extra as Map<String, Object?>?;
          return GanaFormPage(ganaId: args?['ganaId'] as String?);
        },
      ),
      GoRoute(
        name: AppRoutes.shivGanaDetail,
        path: '/gana/:ganaId',
        builder: (_, state) =>
            GanaDetailPage(ganaId: state.pathParameters['ganaId']!),
      ),
      GoRoute(
        name: AppRoutes.brahmaManasForm,
        path: '/brahma/manas/form',
        builder: (_, __) => const ManasFormPage(),
      ),
    ],
  );

  Future<void> removeGanasNamed(String name) async {
    final result = await getIt<GetGanasUseCase>().call();
    final ids = result.fold(
      (_) => <String>[],
      (items) =>
          items.where((g) => g.name == name).map((g) => g.ganaId).toList(),
    );
    for (final id in ids) {
      await getIt<DeleteGanaUseCase>().call(id);
    }
  }

  Future<void> revealInGanaForm(WidgetTester tester, Finder target) async {
    final scrollable = find
        .descendant(
          of: find.byType(GanaFormPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(target, 220, scrollable: scrollable);
    await tester.pumpAndSettle();
    final bottom = tester.getRect(find.byType(GanaFormPage)).bottom;
    final targetBottom = tester.getRect(target).bottom;
    if (targetBottom > bottom - 130) {
      await tester.drag(scrollable, Offset(0, -(targetBottom - bottom + 210)));
      await tester.pumpAndSettle();
    }
  }

  const scopePrefix = 'e2e-gana-scope-262';
  const scopeManasId = '$scopePrefix-manas';
  const scopeSelf = '$scopePrefix-self';

  Future<void> clearScopeFixture() async {
    await isar.writeTxn(() async {
      await isar.manasNoteLinkModels
          .filter()
          .manasIdEqualTo(scopeManasId)
          .deleteAll();
      await isar.manasModels.filter().manasIdEqualTo(scopeManasId).deleteAll();
      await isar.savedNoteModels
          .filter()
          .eventIdStartsWith(scopePrefix)
          .deleteAll();
      await isar.noteModels.filter().eventIdStartsWith(scopePrefix).deleteAll();
      await isar.draftModels
          .filter()
          .draftIdStartsWith(scopePrefix)
          .deleteAll();
    });
  }

  Future<void> seedScopeFixture() async {
    await clearScopeFixture();
    final first = DateTime(2099, 1, 1);
    final removedAt = DateTime(2099, 1, 8);
    NoteModel note(
      String id,
      String content,
      String author,
      DateTime created,
    ) => NoteModel(
      eventId: '$scopePrefix-$id',
      sig: 'test',
      authorPubkey: author,
      content: content,
      type: NoteType.text,
      eTagRefs: const [],
      pTagRefs: const [],
      tTags: const [],
      created: created,
    );
    SavedNoteModel saved(
      String id,
      String content,
      DateTime created, {
      DateTime? removed,
    }) => SavedNoteModel()
      ..eventId = '$scopePrefix-$id'
      ..sig = 'test'
      ..authorPubkey = 'other'
      ..content = content
      ..type = NoteType.text
      ..eTagRefs = const []
      ..pTagRefs = const []
      ..tTags = const []
      ..created = created
      ..savedAt = created
      ..removedAt = removed;
    ManasNoteLinkModel link(String noteId, {DateTime? removed}) =>
        ManasNoteLinkModel()
          ..manasId = scopeManasId
          ..noteId = '$scopePrefix-$noteId'
          ..addedAt = first
          ..removedAt = removed;

    await isar.writeTxn(() async {
      await isar.manasModels.put(
        ManasModel()
          ..manasId = scopeManasId
          ..name = 'Scope test Manas'
          ..createdAt = first
          ..updatedAt = first,
      );
      await isar.savedNoteModels.putAll([
        saved('saved', 'SAVED-ALPHA-262', first.add(const Duration(days: 1))),
        saved('removed-save', 'REMOVED-SAVE-262', first, removed: removedAt),
      ]);
      await isar.noteModels.putAll([
        note(
          'own',
          'OWN-BETA-262',
          scopeSelf,
          first.add(const Duration(days: 2)),
        ),
        note(
          'linked',
          'LINKED-DELTA-262',
          'other',
          first.add(const Duration(days: 4)),
        ),
        note(
          'unrelated',
          'UNRELATED-PEER-262',
          'other',
          first.add(const Duration(days: 5)),
        ),
        note(
          'removed-link',
          'REMOVED-LINK-262',
          'other',
          first.add(const Duration(days: 6)),
        ),
      ]);
      await isar.draftModels.put(
        DraftModel()
          ..draftId = '$scopePrefix-draft'
          ..content = 'DRAFT-GAMMA-262'
          ..eTagRefs = const []
          ..pTagRefs = const []
          ..tTags = const []
          ..createdAt = first.add(const Duration(days: 3))
          ..updatedAt = first.add(const Duration(days: 3)),
      );
      await isar.manasNoteLinkModels.putAll([
        link('linked'),
        link('removed-link', removed: removedAt),
      ]);
    });
  }

  test(
    'Brahma loaders include each eligible note source and prompt content',
    () async {
      await seedScopeFixture();
      try {
        final loader = getIt<ManasContextLoader>();
        final foreground = await loader.mergeAll(
          selfPubkey: scopeSelf,
          budget: 1000,
        );
        final background = await ManasContextLoader.packAllNewest(
          isar: isar,
          selfPubkey: scopeSelf,
          budget: 1000,
        );
        final expected = [
          '$scopePrefix-linked',
          '$scopePrefix-draft',
          '$scopePrefix-own',
          '$scopePrefix-saved',
        ];
        expect(foreground.take(4).map((n) => n.id), expected);
        expect(background.take(4).map((n) => n.id), expected);
        for (final notes in [foreground, background]) {
          final ids = notes.map((n) => n.id).toSet();
          expect(ids, containsAll(expected));
          expect(ids, isNot(contains('$scopePrefix-unrelated')));
          expect(ids, isNot(contains('$scopePrefix-removed-link')));
          expect(ids, isNot(contains('$scopePrefix-removed-save')));
        }

        final prepared = await prepareGanaRun(
          isar: isar,
          gana: aGana(taskPrompt: 'Use the knowledge notes'),
          selfPubkeyHex: scopeSelf,
          selfOutputs: const {},
          loadKnowledge: (_) =>
              loader.mergeAll(selfPubkey: scopeSelf, budget: 1000),
        );
        expect(prepared, isNotNull);
        expect(
          prepared!.prompt,
          contains("KNOWLEDGE — the user's notes (Brahma)"),
        );
        for (final marker in [
          'SAVED-ALPHA-262',
          'OWN-BETA-262',
          'DRAFT-GAMMA-262',
          'LINKED-DELTA-262',
        ]) {
          expect(prepared.prompt, contains(marker));
        }
        expect(prepared.prompt, isNot(contains('UNRELATED-PEER-262')));
        expect(prepared.prompt, isNot(contains('REMOVED-LINK-262')));
        expect(prepared.prompt, isNot(contains('REMOVED-SAVE-262')));
      } finally {
        await clearScopeFixture();
      }
    },
  );

  test(
    'Manas stays isolated while Brahma expands, with bounded context',
    () async {
      await seedScopeFixture();
      try {
        final loader = getIt<ManasContextLoader>();
        final manas = await loader.merge(
          manasIds: const [scopeManasId],
          budget: 1000,
        );
        expect(manas.map((n) => n.id), ['$scopePrefix-linked']);

        final selected = await prepareGanaRun(
          isar: isar,
          gana: aGana(manasIds: const [scopeManasId]),
          selfPubkeyHex: scopeSelf,
          selfOutputs: const {},
          loadKnowledge: (_) =>
              loader.merge(manasIds: const [scopeManasId], budget: 1000),
        );
        expect(selected!.prompt, contains('LINKED-DELTA-262'));
        expect(selected.prompt, isNot(contains('SAVED-ALPHA-262')));
        expect(selected.prompt, contains('Manas: Scope test Manas'));

        final brahma = await ManasContextLoader.packAllNewest(
          isar: isar,
          selfPubkey: scopeSelf,
          budget: 8,
        );
        expect(brahma.take(1).map((n) => n.id), ['$scopePrefix-linked']);
        expect(brahma.any((n) => n.id == '$scopePrefix-saved'), isFalse);
        expect(
          brahma.fold<int>(0, (n, note) => n + note.content.length),
          lessThanOrEqualTo((8 * 4 * 0.85).floor()),
        );
        expect(
          await loader.mergeAll(selfPubkey: scopeSelf, budget: 0),
          isEmpty,
        );
        expect(
          await ManasContextLoader.packAllNewest(
            isar: isar,
            selfPubkey: scopeSelf,
            budget: -1,
          ),
          isEmpty,
        );
      } finally {
        await clearScopeFixture();
      }
    },
  );

  test(
    'all five input surfaces filter unrelated, own, repeated and old notes',
    () async {
      const prefix = 'e2e-gana-input-262';
      final created = DateTime(2099, 2, 1);
      Future<void> cleanup() async {
        await isar.writeTxn(() async {
          await isar.noteModels.filter().eventIdStartsWith(prefix).deleteAll();
        });
      }

      NoteModel note(
        String id, {
        required int kind,
        String author = 'other',
        String? groupId,
        String? privateGroupId,
        int? conversationId,
        List<String> eTagRefs = const [],
        DateTime? at,
      }) => NoteModel(
        eventId: '$prefix-$id',
        sig: 'test',
        authorPubkey: author,
        content: 'INPUT-$id',
        kind: kind,
        groupId: groupId,
        privateGroupId: privateGroupId,
        conversationId: conversationId,
        type: NoteType.text,
        eTagRefs: eTagRefs,
        pTagRefs: const [],
        tTags: const [],
        created: at ?? created,
      );

      await cleanup();
      try {
        await isar.writeTxn(() async {
          await isar.noteModels.putAll([
            note('group', kind: kGroupMessageKind, groupId: '$prefix-group'),
            note(
              'private',
              kind: kPrivateGroupKind,
              privateGroupId: '$prefix-private',
            ),
            note('dm', kind: kDmTextKind, conversationId: 262262),
            note('user', kind: kNoteKind, author: '$prefix-author'),
            note('followed', kind: kNoteKind, eTagRefs: const ['$prefix-root']),
            note(
              'wrong-group',
              kind: kGroupMessageKind,
              groupId: '$prefix-other-group',
            ),
            note(
              'wrong-private',
              kind: kPrivateGroupKind,
              privateGroupId: '$prefix-other-private',
            ),
            note('wrong-dm', kind: kDmTextKind, conversationId: 262263),
            note('wrong-user', kind: kNoteKind, author: '$prefix-other-author'),
            note(
              'wrong-followed',
              kind: kNoteKind,
              eTagRefs: const ['$prefix-other-root'],
            ),
            note(
              'own-group',
              kind: kGroupMessageKind,
              groupId: '$prefix-group',
              author: scopeSelf,
            ),
            note(
              'old-group',
              kind: kGroupMessageKind,
              groupId: '$prefix-group',
              at: created.subtract(const Duration(days: 1)),
            ),
          ]);
        });

        final cases = <(GanaInputType, String, String)>[
          (GanaInputType.group, '$prefix-group', '$prefix-group'),
          (GanaInputType.privateGroup, '$prefix-private', '$prefix-private'),
          (GanaInputType.dm, '262262', '$prefix-dm'),
          (GanaInputType.user, '$prefix-author', '$prefix-user'),
          (GanaInputType.followedNote, '$prefix-root', '$prefix-followed'),
        ];
        for (final (type, ref, expectedId) in cases) {
          final gana = aGana().copyWith(inputType: type, inputRefId: ref);
          final inputs = await GanaInputFilter.fetch(
            isar: isar,
            gana: gana,
            selfPubkeyHex: scopeSelf,
            selfOutputEventIds: const {},
          );
          expect(
            inputs.map((n) => n.eventId),
            contains(expectedId),
            reason: '${type.name} should read its own surface',
          );
          for (final unrelated in [
            'wrong-group',
            'wrong-private',
            'wrong-dm',
            'wrong-user',
            'wrong-followed',
          ]) {
            expect(
              inputs.map((n) => n.eventId),
              isNot(contains('$prefix-$unrelated')),
            );
          }

          final prepared = await prepareGanaRun(
            isar: isar,
            gana: gana,
            selfPubkeyHex: scopeSelf,
            selfOutputs: const {},
            loadKnowledge: (_) async => const [],
          );
          expect(
            prepared?.prompt,
            contains('INPUT-${expectedId.substring(prefix.length + 1)}'),
          );
        }

        final group = aGana().copyWith(
          inputType: GanaInputType.group,
          inputRefId: '$prefix-group',
        );
        final filtered = await GanaInputFilter.fetch(
          isar: isar,
          gana: group,
          selfPubkeyHex: scopeSelf,
          selfOutputEventIds: const {'$prefix-group'},
        );
        expect(
          filtered.map((n) => n.eventId),
          isNot(contains('$prefix-group')),
        );
        expect(
          filtered.map((n) => n.eventId),
          isNot(contains('$prefix-own-group')),
        );

        final afterCursor = await GanaInputFilter.fetch(
          isar: isar,
          gana: group.copyWith(lastProcessedCreated: created),
          selfPubkeyHex: scopeSelf,
          selfOutputEventIds: const {},
        );
        expect(afterCursor, isEmpty);
        expect(
          await GanaInputFilter.fetch(
            isar: isar,
            gana: aGana().copyWith(
              inputType: GanaInputType.dm,
              inputRefId: 'not-a-conversation-id',
            ),
            selfPubkeyHex: scopeSelf,
            selfOutputEventIds: const {},
          ),
          isEmpty,
        );
        expect(
          await prepareGanaRun(
            isar: isar,
            gana: group.copyWith(inputRefId: '$prefix-empty'),
            selfPubkeyHex: scopeSelf,
            selfOutputs: const {},
            loadKnowledge: (_) async => const [],
          ),
          isNull,
        );
      } finally {
        await cleanup();
      }
    },
  );

  testWidgets(
    'Brahma scope saves a Gana with no Manas and appears on dashboard',
    (tester) async {
      const ganaName = 'E2E Brahma Gana 262';
      final router = ganaRouter();
      try {
        await removeGanasNamed(ganaName);
        await tester.pumpWidget(
          MaterialApp.router(
            theme: AppTheme.light,
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        );
        await tester.pumpAndSettle();
        final newButton = find
            .ancestor(of: find.text('New'), matching: find.byType(TextButton))
            .first;
        await tester.tap(newButton);
        await tester.pumpAndSettle();
        expect(find.byType(GanaFormPage), findsOneWidget);
        final save = find.ancestor(
          of: find.text('Save'),
          matching: find.byType(FilledButton),
        );
        expect(tester.widget<FilledButton>(save).onPressed, isNull);
        await tester.enterText(find.byType(TextField).first, ganaName);
        await tester.enterText(
          find.byType(TextField).at(1),
          'Summarize Brahma',
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(save).onPressed, isNull);

        final preset = find.text('Once, when I enable it');
        await revealInGanaForm(tester, preset);
        await tester.tap(preset);
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
        await tester.tap(save);
        await tester.pumpAndSettle();

        final result = await getIt<GetGanasUseCase>().call();
        final saved = result.fold(
          (_) => throw StateError('Could not load saved Gana'),
          (items) => items.singleWhere((g) => g.name == ganaName),
        );
        expect(saved.manasIds, isEmpty);
        expect(saved.taskPrompt, 'Summarize Brahma');
        expect(saved.enabled, isFalse);
        expect(find.text(ganaName), findsWidgets);
        expect(find.text('Brahma'), findsWidgets);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        await removeGanasNamed(ganaName);
      }
    },
  );

  testWidgets(
    'No knowledge saves a Gana that uses no notes and shows it on the dashboard',
    (tester) async {
      const ganaName = 'E2E No-knowledge Gana';
      final router = ganaRouter();
      try {
        await removeGanasNamed(ganaName);
        await tester.pumpWidget(
          MaterialApp.router(
            theme: AppTheme.light,
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        );
        await tester.pumpAndSettle();
        final newButton = find
            .ancestor(of: find.text('New'), matching: find.byType(TextButton))
            .first;
        await tester.tap(newButton);
        await tester.pumpAndSettle();
        final save = find.ancestor(
          of: find.text('Save'),
          matching: find.byType(FilledButton),
        );
        await tester.enterText(find.byType(TextField).first, ganaName);
        await tester.enterText(find.byType(TextField).at(1), 'Say hello');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();

        final none = find.text('No knowledge');
        await revealInGanaForm(tester, none);
        await tester.tap(none);
        await tester.pumpAndSettle();

        final preset = find.text('Once, when I enable it');
        await revealInGanaForm(tester, preset);
        await tester.tap(preset);
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
        await tester.tap(save);
        await tester.pumpAndSettle();

        final result = await getIt<GetGanasUseCase>().call();
        final saved = result.fold(
          (_) => throw StateError('Could not load saved Gana'),
          (items) => items.singleWhere((g) => g.name == ganaName),
        );
        expect(saved.noKnowledge, isTrue);
        expect(saved.manasIds, isEmpty);
        expect(find.text(ganaName), findsWidgets);
        expect(find.text('No knowledge'), findsWidgets);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        await removeGanasNamed(ganaName);
      }
    },
  );

  testWidgets(
    'creating a Manas from a new Gana keeps its draft and adds the picker choice',
    (tester) async {
      const ganaName = 'Draft Gana 262';
      const manasName = 'E2E Gana new Manas 262';
      final getManases = getIt<GetManasListUseCase>();
      final deleteManas = getIt<DeleteManasUseCase>();
      final router = ganaRouter();

      Future<void> removeCreatedManas() async {
        final result = await getManases.call();
        final manases = result.fold(
          (_) => <String>[],
          (items) => items
              .where((m) => m.name == manasName)
              .map((m) => m.manasId)
              .toList(),
        );
        for (final id in manases) {
          await deleteManas.call(id);
        }
      }

      try {
        await removeCreatedManas();
        await removeGanasNamed(ganaName);
        await tester.pumpWidget(
          MaterialApp.router(
            theme: AppTheme.light,
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        );
        await tester.pumpAndSettle();
        final newButton = find
            .ancestor(of: find.text('New'), matching: find.byType(TextButton))
            .first;
        await tester.tap(newButton);
        await tester.pumpAndSettle();

        await tester.enterText(find.byType(TextField).first, ganaName);
        await tester.enterText(
          find.byType(TextField).at(1),
          'Summarize the notes',
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        final originalId = BlocProvider.of<GanaFormBloc>(
          tester.element(find.text('New Gana')),
        ).state.ganaId;
        expect(
          BlocProvider.of<GanaFormBloc>(
            tester.element(find.text('New Gana')),
          ).state.manases,
          isEmpty,
        );
        final create = find.text('Create Manas');
        await revealInGanaForm(tester, create.first);
        expect(
          find.ancestor(of: create, matching: find.byType(FilledButton)),
          findsOneWidget,
        );
        await tester.tap(create.first);
        await tester.pumpAndSettle();

        expect(find.byType(ManasFormPage), findsOneWidget);
        await tester.enterText(find.byType(TextField).first, manasName);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        expect(find.byType(GanaFormPage), findsOneWidget);
        expect(find.text('New Gana'), findsOneWidget);
        expect(find.text('Gana not found'), findsNothing);
        expect(find.text(manasName), findsOneWidget);
        final returned = BlocProvider.of<GanaFormBloc>(
          tester.element(find.text('New Gana')),
        ).state;
        expect(returned.ganaId, originalId);
        expect(returned.name, ganaName);
        expect(returned.taskPrompt, 'Summarize the notes');
        expect(returned.status, GanaFormStatus.ready);
        expect(find.text('Brahma'), findsOneWidget);
        await revealInGanaForm(tester, find.text(manasName));
        await tester.tap(find.text(manasName));
        await tester.pumpAndSettle();
        final newManasChip = find.ancestor(
          of: find.text(manasName),
          matching: find.byType(FilterChip),
        );
        expect(tester.widget<FilterChip>(newManasChip).selected, isTrue);
        final chosenId = returned.manases
            .singleWhere((m) => m.name == manasName)
            .manasId;
        final preset = find.text('Once, when I enable it');
        await revealInGanaForm(tester, preset);
        await tester.tap(preset);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        final result = await getIt<GetGanasUseCase>().call();
        final saved = result.fold(
          (_) => throw StateError('Could not load saved Gana'),
          (items) => items.singleWhere((g) => g.name == ganaName),
        );
        expect(saved.ganaId, originalId);
        expect(saved.manasIds, [chosenId]);
        expect(saved.taskPrompt, 'Summarize the notes');
        expect(saved.enabled, isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        await removeGanasNamed(ganaName);
        await removeCreatedManas();
      }
    },
  );

  testWidgets(
    'editing a Gana keeps its draft through cancel and Manas creation',
    (tester) async {
      const ganaId = 'e2e-gana-262-edit';
      const ganaName = 'E2E Edit Gana 262';
      const initialManasId = 'e2e-gana-262-initial';
      const initialManasName = 'E2E Initial Manas 262';
      const newManasName = 'E2E Added Manas 262';
      final router = ganaRouter();
      final getManases = getIt<GetManasListUseCase>();
      final deleteManas = getIt<DeleteManasUseCase>();

      Future<String?> createdManasId() async {
        final result = await getManases.call();
        return result.fold<String?>(
          (_) => null,
          (items) => items
              .where((m) => m.name == newManasName)
              .map((m) => m.manasId)
              .firstOrNull,
        );
      }

      Future<void> cleanup() async {
        await getIt<DeleteGanaUseCase>().call(ganaId);
        final createdId = await createdManasId();
        if (createdId != null) await deleteManas.call(createdId);
        await deleteManas.call(initialManasId);
      }

      try {
        await cleanup();
        final manasResult = await getIt<UpsertManasUseCase>().call(
          aManas(manasId: initialManasId, name: initialManasName),
        );
        expect(manasResult.isRight(), isTrue);
        final ganaResult = await getIt<UpsertGanaUseCase>().call(
          aGana(
            ganaId: ganaId,
            name: ganaName,
            manasIds: const [initialManasId],
            taskPrompt: 'Keep this instruction',
            triggerMode: GanaTriggerMode.oneShot,
          ),
        );
        expect(ganaResult.isRight(), isTrue);

        await tester.pumpWidget(
          MaterialApp.router(
            theme: AppTheme.light,
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        );
        await tester.pumpAndSettle();
        router.pushNamed(
          AppRoutes.shivGanaDetail,
          pathParameters: {'ganaId': ganaId},
        );
        await tester.pumpAndSettle();
        expect(find.byType(GanaDetailPage), findsOneWidget);
        await tester.tap(find.byIcon(Icons.edit_outlined));
        await tester.pumpAndSettle();

        GanaFormState formState() => BlocProvider.of<GanaFormBloc>(
          tester.element(find.text('Edit · $ganaName')),
        ).state;
        expect(formState().isEditMode, isTrue);
        expect(formState().selectedManasId, initialManasId);
        expect(formState().name, ganaName);
        expect(formState().taskPrompt, 'Keep this instruction');
        final create = find.text('Create Manas');
        await revealInGanaForm(tester, create.first);
        expect(
          find.ancestor(of: create, matching: find.byType(ActionChip)),
          findsOneWidget,
        );

        await tester.tap(create.first);
        await tester.pumpAndSettle();
        expect(find.byType(ManasFormPage), findsOneWidget);
        await tester.tap(find.byType(UniunBackButton));
        await tester.pumpAndSettle();
        expect(formState().ganaId, ganaId);
        expect(formState().selectedManasId, initialManasId);
        expect(formState().name, ganaName);

        await tester.tap(create.first);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, newManasName);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        expect(find.byType(GanaFormPage), findsOneWidget);
        expect(formState().ganaId, ganaId);
        expect(formState().selectedManasId, initialManasId);
        expect(formState().name, ganaName);
        expect(formState().taskPrompt, 'Keep this instruction');
        expect(find.text('Gana not found'), findsNothing);
        final addedId = await createdManasId();
        expect(addedId, isNotNull);
        expect(formState().manases.any((m) => m.manasId == addedId), isTrue);

        await revealInGanaForm(tester, find.text(newManasName));
        await tester.tap(find.text(newManasName));
        await tester.pumpAndSettle();
        expect(formState().selectedManasId, addedId);
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        final afterManas = await getIt<GetGanaByIdUseCase>().call(ganaId);
        expect(afterManas.fold((_) => null, (g) => g.manasIds), [addedId]);

        await tester.tap(find.byIcon(Icons.edit_outlined));
        await tester.pumpAndSettle();
        await revealInGanaForm(tester, find.text('Brahma'));
        await tester.tap(find.text('Brahma'));
        await tester.pumpAndSettle();
        expect(formState().selectedManasId, isNull);
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        final afterBrahma = await getIt<GetGanaByIdUseCase>().call(ganaId);
        expect(afterBrahma.fold((_) => null, (g) => g.manasIds), isEmpty);
        expect(find.text('Brahma'), findsWidgets);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        router.dispose();
        await cleanup();
      }
    },
  );

  testWidgets('the dashboard shows seeded Gana numbers and recent runs', (
    tester,
  ) async {
    final now = DateTime.now();

    final ganas = [
      ('Life Lessons Replier', true, 42, 3, 11),
      ('Morning Digest', true, 12, 0, 0),
      ('Group Summariser', false, 0, 5, 2),
    ];
    final runs = [
      ('e2e-g0', GanaRunStatus.succeeded, 4, null),
      ('e2e-g1', GanaRunStatus.succeeded, 35, null),
      ('e2e-g2', GanaRunStatus.failed, 90, 'Native engine closed mid-run'),
    ];

    await isar.writeTxn(() async {
      for (var i = 0; i < ganas.length; i++) {
        final (name, on, ok, bad, skipped) = ganas[i];
        await isar.ganaModels.put(
          GanaModel()
            ..ganaId = 'e2e-g$i'
            ..name = name
            ..manasIds = const []
            ..taskPrompt = 't'
            ..outputType = GanaOutputType.feed
            ..triggerMode = GanaTriggerMode.recurring
            ..enabled = on
            ..runsSucceeded = ok
            ..runsFailed = bad
            ..runsSkipped = skipped
            ..createdAt = now
            ..updatedAt = now,
        );
      }
      for (var i = 0; i < runs.length; i++) {
        final (ganaId, status, minutesAgo, error) = runs[i];
        await isar.ganaRunModels.put(
          GanaRunModel()
            ..runId = 'e2e-r$i'
            ..ganaId = ganaId
            ..startedAt = now.subtract(Duration(minutes: minutesAgo))
            ..status = status
            ..error = error,
        );
      }
    });

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const GanaDashboardPage(),
        ),
      );
      await tester.pump(const Duration(seconds: 2));

      expect(find.text('Dashboard'), findsOneWidget);
      expect(find.text('NEEDS ATTENTION'), findsOneWidget);
      expect(find.text('Native engine closed mid-run'), findsWidgets);
      expect(find.text('42 done · 3 failed · 11 skipped'), findsOneWidget);

      if (_holdSeconds > 0) {
        await tester.pump(const Duration(seconds: _holdSeconds));
      }
    } finally {
      await isar.writeTxn(() async {
        await isar.ganaModels.filter().ganaIdStartsWith('e2e-').deleteAll();
        await isar.ganaRunModels.filter().ganaIdStartsWith('e2e-').deleteAll();
      });
    }
  });

  testWidgets('a Gana run opens to the note it wrote and the reason it failed', (
    tester,
  ) async {
    final now = DateTime.now();

    await isar.writeTxn(() async {
      await isar.ganaModels.put(
        GanaModel()
          ..ganaId = 'e2e-g0'
          ..name = 'Life Lessons Replier'
          ..manasIds = const []
          ..taskPrompt = 't'
          ..outputType = GanaOutputType.feed
          ..triggerMode = GanaTriggerMode.recurring
          ..runsSucceeded = 1
          ..runsFailed = 1
          ..runsSkipped = 1
          ..createdAt = now
          ..updatedAt = now,
      );
      await isar.noteModels.put(
        NoteModel(
          eventId: 'e2e-note-1',
          sig: '',
          authorPubkey: 'e2e',
          content:
              'Small habits compound.\nShow up today, even for five minutes.',
          type: NoteType.text,
          eTagRefs: const [],
          pTagRefs: const [],
          tTags: const [],
          created: now,
        ),
      );
      for (final r in [
        ('e2e-r0', GanaRunStatus.succeeded, 4, null, 'e2e-note-1'),
        (
          'e2e-r1',
          GanaRunStatus.failed,
          40,
          'SocketException: Failed host lookup: api.uniun.in',
          null,
        ),
        ('e2e-r2', GanaRunStatus.skipped, 90, null, null),
      ]) {
        await isar.ganaRunModels.put(
          GanaRunModel()
            ..runId = r.$1
            ..ganaId = 'e2e-g0'
            ..startedAt = now.subtract(Duration(minutes: r.$3))
            ..status = r.$2
            ..error = r.$4
            ..outputEventId = r.$5
            ..skipReason = r.$2 == GanaRunStatus.skipped
                ? GanaSkipReason.noNewInput
                : null
            ..inputEventIds = r.$2 == GanaRunStatus.succeeded
                ? const ['a', 'b']
                : const [],
        );
      }
    });

    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const GanaDetailPage(ganaId: 'e2e-g0'),
        ),
      );
      await tester.pump(const Duration(seconds: 2));

      // The first two runs, newest first: the published note, then the failure.
      await tester.tap(find.text('Failed · 40m ago'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Succeeded · 4m ago'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Small habits compound.'), findsOneWidget);
      expect(find.text('Network problem'), findsWidgets);
      expect(find.textContaining('Failed host lookup'), findsOneWidget);

      if (_holdSeconds > 0) {
        await tester.pump(const Duration(seconds: _holdSeconds));
      }
    } finally {
      await isar.writeTxn(() async {
        await isar.ganaModels.filter().ganaIdStartsWith('e2e-').deleteAll();
        await isar.ganaRunModels.filter().ganaIdStartsWith('e2e-').deleteAll();
        await isar.noteModels.filter().eventIdStartsWith('e2e-').deleteAll();
      });
    }
  });
}
