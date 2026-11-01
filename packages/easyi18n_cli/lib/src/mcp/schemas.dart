import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:path/path.dart' as p;

import '../exceptions.dart';

/// Shared input-schema pieces. Every tool schema closes
/// `additionalProperties`: an argument the server does not know — `token`
/// above all — is a rejected call, not a silently ignored field (D3).
ObjectSchema toolSchema({
  Map<String, Schema> properties = const {},
  List<String> required = const [],
}) => ObjectSchema(
  properties: {'project_dir': projectDirSchema, ...properties},
  required: required.isEmpty ? null : required,
  additionalProperties: false,
);

final projectDirSchema = Schema.string(
  description:
      'Absolute path to the project root. Defaults to '
      r'$EASYI18N_PROJECT_DIR, then the server process working directory.',
);

String? stringArg(CallToolRequest request, String name) =>
    request.arguments?[name] as String?;

bool? boolArg(CallToolRequest request, String name) =>
    request.arguments?[name] as bool?;

/// The caller's `source_dir`, refused unless it resolves inside [root].
String sourceDirArg(CallToolRequest request, {required String root}) {
  final requested = stringArg(request, 'source_dir') ?? 'lib';
  final base = p.normalize(p.absolute(root));
  final resolved = p.normalize(p.join(base, requested));
  if (resolved != base && !p.isWithin(base, resolved)) {
    throw CliException(
      'source_dir has to stay inside the project root: "$requested" resolves '
      'to "$resolved", outside "$base". Pass a path relative to the root, and '
      'name another project with project_dir.',
      code: 'source_dir_outside_project',
    );
  }
  // followLinks:false does not protect the directory passed to listSync.
  // Reject links in that path, including dangling and intermediate links.
  var current = base;
  if (resolved != base) {
    for (final component in p.split(p.relative(resolved, from: base))) {
      current = p.join(current, component);
      if (FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw CliException(
          'source_dir cannot traverse a symbolic link: "$current". '
          'Use a directory inside the project root, or name the linked '
          'project with project_dir.',
          code: 'source_dir_outside_project',
        );
      }
    }
  }
  return resolved;
}

int? intArg(CallToolRequest request, String name) {
  final value = request.arguments?[name];
  return value is num ? value.toInt() : null;
}

List<String> stringListArg(CallToolRequest request, String name) => [
  for (final value in request.arguments?[name] as List? ?? const [])
    value as String,
];
