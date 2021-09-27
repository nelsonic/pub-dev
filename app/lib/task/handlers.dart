import 'package:mime/mime.dart';
import 'package:pub_dev/shared/exceptions.dart';
import 'package:pub_dev/shared/handlers.dart';
import 'package:pub_dev/task/backend.dart';
import 'package:shelf/shelf.dart' as shelf;

Future<shelf.Response> handleDartDoc(
  shelf.Request request,
  String package,
  String version,
  String path,
) async {
  InvalidInputException.checkPackageName(package);
  InvalidInputException.checkSemanticVersion(version);

  final bytes = await taskBackend.dartdocPage(package, version, path);
  if (bytes == null) {
    return notFoundHandler(request);
  }

  final mime = lookupMimeType(path, headerBytes: bytes);
  return shelf.Response.ok(bytes, headers: {
    'Content-Type': mime ?? 'application/octect',
  });
}
