import 'package:dartz/dartz.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:uniun/common/widgets/note_card/media_attachment_view.dart';
import 'package:uniun/core/error/failures.dart';
import 'package:uniun/core/router/app_routes.dart';
import 'package:uniun/domain/entities/media/media_blob_entity.dart';
import 'package:uniun/domain/entities/media/media_dim.dart';
import 'package:uniun/domain/usecases/media_usecases.dart';
import 'package:uniun/l10n/app_localizations.dart';

import '../../../_helpers/fixtures.dart';

class _MockDownload extends Mock implements DownloadMediaUseCase {}

MediaBlobEntity _blob({
  String sha = 'sha1',
  String mime = 'image/png',
  int size = 0,
  String? filename,
  String? localPath,
  List<String> urls = const ['https://blossom/sha1'],
  MediaDim? dim,
}) => MediaBlobEntity(
  sha256: sha,
  mime: mime,
  sizeBytes: size,
  filename: filename,
  localPath: localPath,
  serverUrls: urls,
  dim: dim,
);

/// Covers: empty list, image tile download overlay → download success/failure
/// snackbar, image tap to the detail route, video overlay, file card title and
/// subtitle (size units, fallback name, cached vs uncached), and a failed
/// file download surfacing the error. The OS hand-off shells out to
/// xdg-open on Linux, so it is left to device tests.
void main() {
  late _MockDownload download;

  setUpAll(
    () => registerFallbackValue(
      const DownloadMediaInput(sha256: '', url: '', mime: ''),
    ),
  );

  setUp(() async {
    download = _MockDownload();
    await GetIt.instance.reset();
    GetIt.instance.registerSingleton<DownloadMediaUseCase>(download);
  });

  tearDown(() => GetIt.instance.reset());

  Widget host(Widget child, {void Function(String)? onDetail}) {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => Scaffold(body: child),
        ),
        GoRoute(
          name: AppRoutes.mediaDetail,
          path: '/media/:sha256',
          builder: (_, s) {
            onDetail?.call(s.pathParameters['sha256']!);
            return const Scaffold(body: Text('detail-page'));
          },
        ),
      ],
    );
    return MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    );
  }

  testWidgets('no attachments renders nothing', (t) async {
    await t.pumpWidget(host(MediaAttachmentView(note: aNote())));
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('an uncached image shows a download button that fetches it', (
    t,
  ) async {
    when(
      () => download.call(any()),
    ).thenAnswer((_) async => Right(_blob(localPath: '/does/not/exist.png')));
    await t.pumpWidget(
      host(MediaAttachmentView.fromBlobs(attachments: [_blob()])),
    );
    expect(find.text('Download'), findsOneWidget);

    await t.tap(find.text('Download'));
    await t.pump();
    await t.pump();

    final input =
        verify(() => download.call(captureAny())).captured.single
            as DownloadMediaInput;
    expect(input.sha256, 'sha1');
    expect(input.url, 'https://blossom/sha1');
    expect(input.mime, 'image/png');
    expect(find.text('Download'), findsNothing);
  });

  testWidgets('a failed download shows the error and keeps the button', (
    t,
  ) async {
    when(() => download.call(any())).thenAnswer(
      (_) async => const Left(Failure.errorFailure('server said no')),
    );
    await t.pumpWidget(
      host(MediaAttachmentView.fromBlobs(attachments: [_blob()])),
    );
    await t.tap(find.text('Download'));
    await t.pump();
    await t.pump();

    expect(find.text('server said no'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('a blob with no server url does not attempt a download', (
    t,
  ) async {
    await t.pumpWidget(
      host(MediaAttachmentView.fromBlobs(attachments: [_blob(urls: const [])])),
    );
    await t.tap(find.text('Download'));
    await t.pump();
    verifyNever(() => download.call(any()));
  });

  testWidgets('tapping an image opens the media detail route', (t) async {
    String? sha;
    await t.pumpWidget(
      host(
        MediaAttachmentView.fromBlobs(
          attachments: [
            _blob(
              localPath: '/does/not/exist.png',
              dim: const MediaDim(width: 100, height: 200),
            ),
          ],
          compact: false,
        ),
        onDetail: (s) => sha = s,
      ),
    );
    await t.tap(find.byType(GestureDetector).first);
    await t.pumpAndSettle();
    expect(sha, 'sha1');
    expect(find.text('detail-page'), findsOneWidget);
  });

  testWidgets('a video shows a play overlay and no download button', (t) async {
    await t.pumpWidget(
      host(
        MediaAttachmentView.fromBlobs(attachments: [_blob(mime: 'video/mp4')]),
      ),
    );
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    expect(find.text('Download'), findsNothing);
  });

  testWidgets('a file card shows name, type, size and the download hint', (
    t,
  ) async {
    await t.pumpWidget(
      host(
        MediaAttachmentView.fromBlobs(
          attachments: [
            _blob(
              mime: 'application/pdf',
              filename: 'report.pdf',
              size: 3 * 1024 * 1024,
            ),
          ],
        ),
      ),
    );
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.textContaining('3.0 MB'), findsOneWidget);
    expect(find.textContaining('Tap to download'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_download_outlined), findsOneWidget);
  });

  testWidgets('file size units: bytes, kilobytes; blank name falls back', (
    t,
  ) async {
    await t.pumpWidget(
      host(
        Column(
          children: [
            MediaAttachmentView.fromBlobs(
              attachments: [
                _blob(
                  sha: 'a',
                  mime: 'application/zip',
                  filename: '  ',
                  size: 512,
                ),
                _blob(
                  sha: 'b',
                  mime: 'application/zip',
                  filename: 'b.zip',
                  size: 2048,
                ),
                _blob(
                  sha: 'c',
                  mime: 'application/zip',
                  filename: 'c.zip',
                  size: 0,
                ),
              ],
            ),
          ],
        ),
      ),
    );
    expect(find.text('Attachment'), findsOneWidget);
    expect(find.textContaining('512 B'), findsOneWidget);
    expect(find.textContaining('2 KB'), findsOneWidget);
  });

  testWidgets('an uncached file whose download fails shows the error', (t) async {
    when(
      () => download.call(any()),
    ).thenAnswer((_) async => const Left(Failure.errorFailure('offline')));
    await t.pumpWidget(
      host(
        MediaAttachmentView.fromBlobs(
          attachments: [_blob(mime: 'application/pdf', filename: 'a.pdf')],
        ),
      ),
    );
    await t.tap(find.byType(InkWell).first);
    await t.pump();
    await t.pump();

    expect(find.text('offline'), findsOneWidget);
  });
}
