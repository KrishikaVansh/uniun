import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/domain/entities/shiv/shiv_conversation_entity.dart';
import 'package:uniun/features/shiv/chat/widgets/shiv_conversation_tile.dart';
import 'package:uniun/l10n/app_localizations.dart';

ShivConversationEntity _conv({
  String title = 'Plan the week',
  Duration age = Duration.zero,
  DateTime? updatedAt,
}) {
  final at = updatedAt ?? DateTime.now().subtract(age);
  return ShivConversationEntity(
    conversationId: 'c1',
    title: title,
    createdAt: at,
    updatedAt: at,
  );
}

/// Covers: relative-time subtitle at every boundary (now / minutes / hours /
/// days / absolute date), active badge vs chevron, tap forward, swipe-to-
/// delete callback, and long/unicode titles.
void main() {
  Widget host(
    ShivConversationEntity c, {
    bool active = false,
    VoidCallback? onTap,
    VoidCallback? onDelete,
  }) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: ShivConversationTile(
        conversation: c,
        isActive: active,
        onTap: onTap ?? () {},
        onDelete: onDelete ?? () {},
      ),
    ),
  );

  testWidgets('shows the title and a "just now" subtitle for fresh chats', (
    t,
  ) async {
    await t.pumpWidget(host(_conv()));
    expect(find.text('Plan the week'), findsOneWidget);
    expect(find.text('Just now'), findsOneWidget);
  });

  testWidgets('relative time moves through minutes, hours and days', (t) async {
    await t.pumpWidget(
      host(_conv(age: const Duration(minutes: 5, seconds: 1))),
    );
    expect(find.text('5m ago'), findsOneWidget);

    await t.pumpWidget(host(_conv(age: const Duration(hours: 3, minutes: 1))));
    expect(find.text('3h ago'), findsOneWidget);

    await t.pumpWidget(host(_conv(age: const Duration(days: 2, hours: 1))));
    expect(find.text('2d ago'), findsOneWidget);
  });

  testWidgets('a conversation older than a week shows the absolute date', (
    t,
  ) async {
    await t.pumpWidget(host(_conv(updatedAt: DateTime(2020, 3, 7))));
    expect(find.text('7/3/2020'), findsOneWidget);
  });

  testWidgets('active row shows the Active badge, inactive shows a chevron', (
    t,
  ) async {
    await t.pumpWidget(host(_conv(), active: true));
    expect(find.text('Active'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);

    await t.pumpWidget(host(_conv()));
    expect(find.text('Active'), findsNothing);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
  });

  testWidgets('tapping the row fires onTap', (t) async {
    var taps = 0;
    await t.pumpWidget(host(_conv(), onTap: () => taps++));
    await t.tap(find.byType(ListTile));
    expect(taps, 1);
  });

  testWidgets('swiping left deletes, swiping right does not', (t) async {
    var deletes = 0;
    await t.pumpWidget(host(_conv(), onDelete: () => deletes++));

    await t.drag(find.byType(ShivConversationTile), const Offset(500, 0));
    await t.pumpAndSettle();
    expect(deletes, 0);

    await t.drag(find.byType(ShivConversationTile), const Offset(-500, 0));
    await t.pumpAndSettle();
    expect(deletes, 1);
  });

  testWidgets('very long and unicode titles are clamped without overflow', (
    t,
  ) async {
    await t.pumpWidget(host(_conv(title: 'नमस्ते 🌍 ${'long ' * 80}')));
    expect(t.takeException(), isNull);
    expect(find.byType(ListTile), findsOneWidget);
  });
}
