import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uniun/core/theme/app_custom_colors.dart';

/// Covers: copyWith overriding one field and preserving the rest, lerp
/// endpoints / midpoint / non-matching extension, and the context accessor
/// with and without a registered extension.
void main() {
  const light = AppCustomColors.light;
  const dark = AppCustomColors.dark;

  test('copyWith with no arguments is a field-for-field clone', () {
    final c = light.copyWith();
    expect(c, isNot(same(light)));
    expect(c.textMuted, light.textMuted);
    expect(c.graphEdge, light.graphEdge);
    expect(c.shadowPrimary, light.shadowPrimary);
  });

  test('copyWith overrides only the named fields', () {
    const red = Color(0xFFFF0000);
    final c = light.copyWith(success: red, glassFill: red, storageOther: red);
    expect(c.success, red);
    expect(c.glassFill, red);
    expect(c.storageOther, red);
    expect(c.onSuccess, light.onSuccess);
    expect(c.border, light.border);
  });

  test('copyWith can override every field', () {
    const x = Color(0xFF123456);
    final c = light.copyWith(
      iconInactive: x,
      graphSaved: x,
      graphOwn: x,
      graphDraft: x,
      graphNodeSaved: x,
      graphNodeOwn: x,
      graphNodeDraft: x,
      graphDotPattern: x,
      graphEdge: x,
      neutral300: x,
      neutral400: x,
      borderSubtle: x,
      border: x,
      surfaceLow: x,
      textBody: x,
      textMuted: x,
      success: x,
      onSuccess: x,
      storageNotes: x,
      storageModel: x,
      storageChatHistory: x,
      storageOther: x,
      glassFill: x,
      glassBorder: x,
      navShadow: x,
      elevationMd: x,
      shadowPrimary: x,
    );
    for (final v in [
      c.iconInactive,
      c.graphSaved,
      c.graphOwn,
      c.graphDraft,
      c.graphNodeSaved,
      c.graphNodeOwn,
      c.graphNodeDraft,
      c.graphDotPattern,
      c.graphEdge,
      c.neutral300,
      c.neutral400,
      c.borderSubtle,
      c.border,
      c.surfaceLow,
      c.textBody,
      c.textMuted,
      c.success,
      c.onSuccess,
      c.storageNotes,
      c.storageModel,
      c.storageChatHistory,
      c.storageOther,
      c.glassFill,
      c.glassBorder,
      c.navShadow,
      c.elevationMd,
      c.shadowPrimary,
    ]) {
      expect(v, x);
    }
  });

  test('lerp at 0 and 1 returns the endpoints', () {
    final a = light.lerp(dark, 0);
    final b = light.lerp(dark, 1);
    expect(a.textBody, light.textBody);
    expect(a.glassFill, light.glassFill);
    expect(b.textBody, dark.textBody);
    expect(b.shadowPrimary, dark.shadowPrimary);
  });

  test('lerp at 0.5 lands between the two palettes', () {
    final mid = light.lerp(dark, 0.5);
    expect(mid.textBody, Color.lerp(light.textBody, dark.textBody, 0.5));
    expect(
      mid.storageNotes,
      Color.lerp(light.storageNotes, dark.storageNotes, 0.5),
    );
  });

  test('lerp towards a different extension type returns this unchanged', () {
    expect(light.lerp(null, 0.5), same(light));
  });

  testWidgets('context.custom reads the registered extension', (t) async {
    late AppCustomColors read;
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [AppCustomColors.dark]),
        home: Builder(
          builder: (c) {
            read = c.custom;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(read.textBody, dark.textBody);
  });

  testWidgets('context.custom falls back to light when none is registered', (
    t,
  ) async {
    late AppCustomColors read;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            read = c.custom;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(read.textBody, light.textBody);
  });
}
