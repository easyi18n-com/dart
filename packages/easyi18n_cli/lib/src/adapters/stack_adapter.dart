import 'dart:io';

import '../config.dart';
import '../doctor_report.dart';
import '../init_report.dart';

/// Internal stack contract, still evolving through the Xcode and AGENTS phases.
/// Doctor checks must be read-only and must never spend credits.
abstract interface class StackAdapter {
  String get stack;
  String get family;
  bool detect(String root);
  String resolveMode(String root, String? mode, void Function(InitStep) report);
  /// [mode] is what [resolveMode] returned.
  StackConfigDefaults configDefaults(String root, String mode,
      void Function(InitStep) report);
  String nextCommand(Easyi18nConfig config);
  /// The stack's own section of the `AGENTS.md` block: Markdown, one trailing
  /// newline.
  String agentsMdSection(Easyi18nConfig config);
  void initSteps(InitContext context, Easyi18nConfig config);
  Future<void> doctorChecks({required String root, required String sourcePath,
    required Easyi18nConfig config, required DoctorFindings findings});
}

/// What a stack fills into a NEW `easyi18n.yaml` where the flags said nothing.
/// A null field leaves the core default in place, so a stack opts in per field.
/// [sourceLayout] says how the files around `source:` make the catalog.
typedef StackConfigDefaults = ({String? format, String? catalog,
    String? output, String? source, String? sourceLayout});

/// Shared file-writing policy; adapters keep the original ordering of actions.
class InitContext {
  InitContext({required this.root, required this.dryRun,
    required this.onStep, required this.ignoreDerivedState});
  final String root;
  final bool dryRun;
  final void Function(InitStep) onStep;
  /// Optionally positions the common step; the runner always ensures it once.
  final void Function() ignoreDerivedState;

  void write(File file, String content) {
    if (dryRun) return;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  void report(String verb, String target, String detail, {String? scopeSnippet}) =>
      onStep(InitStep(verb, target, detail, scopeSnippet: scopeSnippet));
}
