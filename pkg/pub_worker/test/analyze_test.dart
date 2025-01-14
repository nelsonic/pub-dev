// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async' show Completer;
import 'dart:convert' show json, utf8;
import 'dart:io' show HttpServer, gzip;
import 'dart:typed_data';

import 'package:_pub_shared/data/package_api.dart';
import 'package:_pub_shared/data/task_api.dart';
import 'package:_pub_shared/data/task_payload.dart';
import 'package:indexed_blob/indexed_blob.dart';
import 'package:logging/logging.dart' show Logger, Level, LogRecord;
import 'package:pub_worker/src/analyze.dart' show analyze;
import 'package:pub_worker/src/utils.dart' show streamToBuffer;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:tar/tar.dart';
import 'package:test/test.dart';

import 'multipart.dart' show readMultiparts;

void main() {
  late Map<String, Uint8List> files;
  late Map<String, Completer<void>> _finished;
  setUp(() {
    files = {};
    _finished = {};
  });

  Future<void> waitFor(String package, String version) => _finished
      .putIfAbsent('$package/$version', () => Completer<void>())
      .future;

  late HttpServer server;
  late String baseUrl;

  setUpAll(() async {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen((LogRecord rec) {
      print('${rec.level.name}: ${rec.time}: ${rec.message}');
      if (rec.error != null) {
        print('ERROR: ${rec.error}, ${rec.stackTrace}');
      }
    });

    Map<String, dynamic> packageVersion(
      String package,
      String version,
      Map<String, dynamic> dependencies,
    ) =>
        {
          'version': '$version',
          'archive_url': '$baseUrl/packages/$package/versions/$version.tar.gz',
          'pubspec': {
            'name': '$package',
            'version': '$version',
            'dependencies': dependencies,
            'environment': {'sdk': '>=2.12.0-0 <3.0.0'},
          },
        };

    final app = Router();

    app.get('/api/packages/retry', (Request request) {
      return Response.ok(json.encode({
        'name': 'retry',
        'latest': packageVersion('retry', '3.0.1', {'meta': '^1.0.0'}),
        'versions': [
          packageVersion('retry', '3.0.1', {'meta': '^1.0.0'}),
          packageVersion('retry', '3.0.0', {'meta': '^1.0.0'}),
        ],
      }));
    });

    app.get('/api/packages/meta', (Request request) {
      return Response.ok(json.encode({
        'name': 'meta',
        'latest': packageVersion('meta', '1.0.0', {}),
        'versions': [packageVersion('meta', '1.0.0', {})],
      }));
    });

    app.get('/packages/retry/versions/3.0.0.tar.gz', (request) {
      return Response.ok(Stream<TarEntry>.fromIterable([
        TarEntry.data(
          TarHeader(name: 'pubspec.yaml'),
          json.fuse(utf8).encode({
            'name': 'retry',
            'version': '3.0.0',
            'dependencies': {
              'meta': '^1.0.0',
            },
            'environment': {'sdk': '>=2.12.0-0 <3.0.0'},
          }),
        ),
        TarEntry.data(
          TarHeader(name: 'lib/retry.dart'),
          utf8.encode('''
            void retry(void Function() fn) { for (var i = 0; i < 5; i++) fn();}
          '''),
        ),
      ]).transform(tarWriter).transform(gzip.encoder));
    });

    app.get('/packages/retry/versions/3.0.1.tar.gz', (request) {
      return Response.ok(Stream<TarEntry>.fromIterable([
        TarEntry.data(
          TarHeader(name: 'pubspec.yaml'),
          json.fuse(utf8).encode({
            'name': 'retry',
            'version': '3.0.1',
            'dependencies': {
              'meta': '^1.0.0',
            },
            'environment': {'sdk': '>=2.12.0-0 <3.0.0'},
          }),
        ),
        TarEntry.data(
          TarHeader(name: 'lib/retry.dart'),
          utf8.encode('''
            import 'package:meta/meta.dart';
            @Sealed()
            void retry(void Function() fn) { for (var i = 0; i < 5; i++) fn();}
          '''),
        ),
      ]).transform(tarWriter).transform(gzip.encoder));
    });

    app.get('/packages/meta/versions/1.0.0.tar.gz', (request) {
      return Response.ok(Stream<TarEntry>.fromIterable([
        TarEntry.data(
          TarHeader(name: 'pubspec.yaml'),
          json.fuse(utf8).encode({
            'name': 'meta',
            'version': '1.0.0',
            'dependencies': {},
            'environment': {'sdk': '>=2.12.0-0 <3.0.0'},
          }),
        ),
        TarEntry.data(
          TarHeader(name: 'lib/meta.dart'),
          utf8.encode('''
            class Sealed {}
          '''),
        ),
      ]).transform(tarWriter).transform(gzip.encoder));
    });

    app.post('/api/tasks/<package>/<version>/upload', (
      Request request,
      String package,
      String version,
    ) {
      return Response.ok(json.encode(UploadTaskResultResponse(
        blobId: '42',
        blob: UploadInfo(
          url: '$baseUrl/upload/$package/$version/42.blob',
          fields: {},
        ),
        index: UploadInfo(
          url: '$baseUrl/upload/$package/$version/index.json',
          fields: {},
        ),
      )));
    });

    app.post('/api/tasks/<package>/<version>/finished', (
      Request request,
      String package,
      String version,
    ) {
      _finished
          .putIfAbsent('$package/$version', () => Completer<void>())
          .complete();
      return Response.ok('{}');
    });

    app.post('/upload/<package>/<version>/<name>', (
      Request request,
      String package,
      String version,
      String name,
    ) async {
      if (request.mimeType != 'multipart/form-data') {
        return Response.forbidden('request must be multipart');
      }
      await for (final part in readMultiparts(request)) {
        final contentDisposition = part.headers['content-disposition'] ?? '';
        final field = contentDisposition
            .split(';')
            .map((s) => s.trim())
            .where((s) => s.startsWith('name='))
            .first
            .replaceFirst('name="', '')
            .replaceAll('"', '');
        if (field == 'file') {
          files['$package/$version/$name'] = await streamToBuffer(part);
        } else {
          await part.drain();
        }
      }
      return Response.ok('{}');
    });

    server = await io.serve(app, 'localhost', 0);
    baseUrl = 'http://localhost:${server.port}';
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  test('analyze retry 3.0.0, 3.0.1', () async {
    await Future.wait([
      analyze(Payload(
        package: 'retry',
        pubHostedUrl: baseUrl,
        versions: [
          VersionTokenPair(
            version: '3.0.0',
            token: 'secret-token',
          ),
          VersionTokenPair(
            version: '3.0.1',
            token: 'secret-token',
          ),
        ],
      )),
      () async {
        await waitFor('retry', '3.0.0');

        expect(files, contains('retry/3.0.0/42.blob'));
        expect(files, contains('retry/3.0.0/index.json'));

        // Check that index contains blobId
        final index = BlobIndex.fromBytes(
          files['retry/3.0.0/index.json']!,
        );
        expect(index.blobId, '42');

        // Check that blob can be read using index using categories.json which
        // should be an empty list for retry 3.0.0
        final blob = files['retry/3.0.0/42.blob']!;
        {
          final logRange = index.lookup('log.txt')!;
          final log = utf8.fuse(gzip).decode(blob.sublist(
                logRange.start,
                logRange.end,
              ));
          print(log);
        }
        print(utf8.decode(index.asBytes()));
        final categoriesRange = index.lookup('doc/categories.json')!;
        final categories = json.fuse(utf8).fuse(gzip).decode(blob.sublist(
              categoriesRange.start,
              categoriesRange.end,
            ));
        expect(categories, equals([]));

        // Check that blob contains log.txt
        final logRange = index.lookup('log.txt')!;
        final log = utf8.fuse(gzip).decode(blob.sublist(
              logRange.start,
              logRange.end,
            ));
        // Check that log contains "exited 0"
        expect(log, contains('exited 0'));

        // Check that there is a summary.json
        expect(index.lookup('summary.json'), isNotNull);

        await waitFor('retry', '3.0.1');

        expect(files, contains('retry/3.0.1/42.blob'));
        expect(files, contains('retry/3.0.1/index.json'));
      }(),
    ]);
  }, timeout: Timeout(Duration(minutes: 5)));
}
