import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

import 'pending_code_change.dart';

/// A single call site to rewrite: the `tr('old')` string literal at
/// [offset]..[end] in [absPath] becomes the encoded [newSource].
class TrEdit {
  const TrEdit({
    required this.absPath,
    required this.file,
    required this.line,
    required this.oldSource,
    required this.newSource,
    required this.ctx,
    required this.offset,
    required this.end,
  });

  final String absPath;
  final String file; // relative, for display
  final int line;
  final String oldSource;
  final String newSource;
  final String? ctx;
  final int offset;
  final int end;
}

/// The outcome of matching the pending changes against the source tree.
class RewritePlan {
  const RewritePlan({
    required this.edits,
    required this.unmatched,
    required this.filesScanned,
  });

  /// Every matched call site (a change may match more than one).
  final List<TrEdit> edits;

  /// Changes with no static call site found — the dev already updated them,
  /// they moved to a variable/interpolation (auto-capture territory), or the
  /// ctx differs. Reported so nothing silently vanishes.
  final List<PendingCodeChange> unmatched;

  final int filesScanned;

  bool get isEmpty => edits.isEmpty;
}

/// AST-aware rewriter for `easyi18n apply`: finds the `tr('old', ctx:)` literals
/// a source-verify fix retired and rewrites them to the corrected source,
/// touching only the string literal (quotes, args, and formatting are left
/// intact). Matches the exact `(source, ctx)` pair — a `ctx` mismatch is a
/// different key, so it is left alone.
///
/// Recognizes the same call shapes as the extractor
/// (`extract/tr_extractor.dart`) so a string `push` registered is one `apply`
/// can rewrite:
///
///   context.tr('Welcome', ctx: 'noun')   // canonical
///   'Welcome'.tr()                        // sugar
class TrRewriter {
  /// Scans every `.dart` file under [dir] and matches [changes] against the
  /// `tr()` call sites. Nothing is written — see [applyPlan].
  RewritePlan plan(
    Directory dir,
    List<PendingCodeChange> changes, {
    String? relativeTo,
  }) {
    final base = relativeTo ?? dir.path;
    // Index the changes by (oldSource, ctx) so a call site is an O(1) lookup;
    // a null newSource-equals-old or a no-op change is dropped up front.
    final byIdentity = <String, PendingCodeChange>{};
    for (final c in changes) {
      if (c.newSource == c.oldSource) continue;
      byIdentity[c.identity] = c;
    }

    final edits = <TrEdit>[];
    final matched = <String>{};
    var filesScanned = 0;

    if (dir.existsSync()) {
      for (final file in _dartFiles(dir)) {
        filesScanned++;
        final String content;
        try {
          content = file.readAsStringSync();
        } on FileSystemException {
          continue;
        }
        final parsed = _tryParse(content, file.path);
        if (parsed == null) continue;
        final rel = p.relative(file.path, from: base);
        final visitor = _RewriteVisitor(parsed.lineInfo, byIdentity);
        parsed.unit.visitChildren(visitor);
        for (final m in visitor.matches) {
          matched.add(m.change.identity);
          edits.add(
            TrEdit(
              absPath: file.path,
              file: rel,
              line: m.line,
              oldSource: m.change.oldSource,
              newSource: m.change.newSource,
              ctx: m.change.ctx,
              offset: m.offset,
              end: m.end,
            ),
          );
        }
      }
    }

    final unmatched = [
      for (final c in byIdentity.values)
        if (!matched.contains(c.identity)) c,
    ];
    return RewritePlan(
      edits: edits,
      unmatched: unmatched,
      filesScanned: filesScanned,
    );
  }

  /// Applies [plan] to disk. Edits are grouped per file and spliced from the
  /// end backwards so earlier offsets stay valid. Returns the number of files
  /// changed. A file whose content shifted since [plan] (an offset past its
  /// end) is skipped defensively.
  int applyPlan(RewritePlan plan) {
    final byFile = <String, List<TrEdit>>{};
    for (final e in plan.edits) {
      (byFile[e.absPath] ??= []).add(e);
    }
    var filesChanged = 0;
    byFile.forEach((path, fileEdits) {
      final file = File(path);
      var content = file.readAsStringSync();
      fileEdits.sort((a, b) => b.offset.compareTo(a.offset)); // descending
      var changed = false;
      for (final e in fileEdits) {
        if (e.end > content.length || e.offset < 0) continue;
        content = content.replaceRange(
          e.offset,
          e.end,
          encodeDartString(e.newSource),
        );
        changed = true;
      }
      if (changed) {
        file.writeAsStringSync(content);
        filesChanged++;
      }
    });
    return filesChanged;
  }

  ParsedUnit? _tryParse(String content, String path) {
    try {
      final parsed = parseString(
        content: content,
        path: path,
        throwIfDiagnostics: false,
      );
      return ParsedUnit(parsed.unit, parsed.lineInfo);
    } catch (_) {
      return null; // an unparseable file shouldn't abort the whole run
    }
  }

  /// Sorted by path, like `TrExtractor`: `listSync` order is the
  /// filesystem's, and `apply` prints and emits the edits in walk order
  /// (#1465).
  List<File> _dartFiles(Directory dir) => [
    for (final entity in dir.listSync(recursive: true, followLinks: false))
      if (entity is File &&
          entity.path.endsWith('.dart') &&
          !entity.path.endsWith('.g.dart') &&
          !entity.path.endsWith('.freezed.dart'))
        entity,
  ]..sort((a, b) => a.path.compareTo(b.path));
}

/// Re-encodes [value] as a single-quoted Dart string literal, escaping the
/// characters that would otherwise change its meaning. `{placeholder}` braces
/// are literal in a `tr()` source and need no escaping.
String encodeDartString(String value) {
  final b = StringBuffer("'");
  for (final rune in value.runes) {
    switch (rune) {
      case 0x5C: // backslash
        b.write(r'\\');
      case 0x27: // single quote
        b.write(r"\'");
      case 0x24: // dollar — would start interpolation
        b.write(r'\$');
      case 0x0A:
        b.write(r'\n');
      case 0x0D:
        b.write(r'\r');
      case 0x09:
        b.write(r'\t');
      default:
        b.writeCharCode(rune);
    }
  }
  b.write("'");
  return b.toString();
}

class ParsedUnit {
  ParsedUnit(this.unit, this.lineInfo);
  final CompilationUnit unit;
  final LineInfo lineInfo;
}

class _Match {
  _Match({
    required this.change,
    required this.offset,
    required this.end,
    required this.line,
  });
  final PendingCodeChange change;
  final int offset;
  final int end;
  final int line;
}

/// Visitor twin of `_TrVisitor` in the extractor — same call-shape gating, but
/// it records the source literal's range for the ones that match a pending
/// change instead of collecting every source.
class _RewriteVisitor extends RecursiveAstVisitor<void> {
  _RewriteVisitor(this._lineInfo, this._byIdentity);

  final LineInfo _lineInfo;
  final Map<String, PendingCodeChange> _byIdentity;
  final matches = <_Match>[];

  static const _contextNames = {'context', 'ctx', 'c'};

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'tr') _handle(node);
    super.visitMethodInvocation(node);
  }

  // Mirrors `_TrVisitor._handle` in extract/tr_extractor.dart (same call-shape
  // gating); differs only at the tail — records the literal's range for a
  // matched pending change instead of collecting every source.
  void _handle(MethodInvocation node) {
    final line = _lineInfo.getLocation(node.offset).lineNumber;
    final target = node.target;
    final isSugar = target is StringLiteral;
    final isCanonical =
        target == null ||
        (target is SimpleIdentifier && _contextNames.contains(target.name));
    if (!isSugar && !isCanonical) return;

    final positional = node.argumentList.arguments.where(
      (a) => a is! NamedArgument,
    );
    final Expression? sourceExpr;
    if (isSugar) {
      sourceExpr = target;
    } else if (positional.isNotEmpty) {
      sourceExpr = positional.first.argumentExpression;
    } else {
      return;
    }
    final value = sourceExpr is StringLiteral ? sourceExpr.stringValue : null;
    if (value == null) return; // interpolated/adjacent — auto-capture territory

    final (ctx, ctxIsStatic) = _ctxArg(node);
    if (!ctxIsStatic) return;

    final identity = '${value.length}:$value:${ctx ?? ''}';
    final change = _byIdentity[identity];
    if (change == null) return;

    matches.add(
      _Match(
        change: change,
        offset: sourceExpr.offset,
        end: sourceExpr.end,
        line: line,
      ),
    );
  }

  (String?, bool) _ctxArg(MethodInvocation node) {
    for (final a in node.argumentList.arguments) {
      if (a is NamedArgument && a.name.lexeme == 'ctx') {
        final v = a.argumentExpression;
        if (v is NullLiteral) return (null, true);
        final literal = v is StringLiteral ? v.stringValue : null;
        return (literal, literal != null);
      }
    }
    return (null, true);
  }
}
