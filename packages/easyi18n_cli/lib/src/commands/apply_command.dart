import 'dart:io';

import 'package:args/command_runner.dart';

import '../api_client.dart';
import '../apply/tr_rewriter.dart';
import '../apply_runner.dart';
import '../cli_output.dart';
import '../config.dart';
import '../logger.dart';
import '../session.dart' show requireCredential;

/// Builds the API client `apply` talks to. Injected so tests can swap in a
/// `MockClient`-backed instance.
typedef ApiClientFactory =
    TranslationsApiClient Function({
      required String baseUrl,
      required String token,
    });

/// `easyi18n apply` - pull the open "update your code" list from source review
/// (`GET /v1/projects/{id}/pending-code-changes`) and rewrite the retired
/// `tr('old')` literals to their corrected form, AST-aware. A preview by
/// default; `--write` edits the files. Local + free (no credits) and reversible
/// through git — after applying, `push` reconciles the entries automatically.
class ApplyCommand extends Command<int> with JsonPresenter {
  ApplyCommand({
    required this.output,
    ApiClientFactory? apiClientFactory,
    TrRewriter? rewriter,
    Map<String, String>? environment,
  }) : _apiClientFactory = apiClientFactory,
       _runner = ApplyRunner(rewriter: rewriter),
       _environment = environment ?? Platform.environment {
    argParser
      ..addOption(
        'token',
        help:
            'API key (eik_) with the read scope. '
            'Defaults to \$EASYI18N_TOKEN, then your easyi18n login.',
      )
      ..addOption(
        'source-dir',
        help: 'Directory to scan and rewrite, relative to the config file.',
        defaultsTo: 'lib',
      )
      ..addFlag(
        'write',
        negatable: false,
        help: 'Apply the rewrites to disk (default is a preview only).',
      );
  }

  CliLogger get _logger => output.logger;
  final ApiClientFactory? _apiClientFactory;
  final ApplyRunner _runner;
  final CliOutput output;
  final Map<String, String> _environment;

  @override
  String get name => 'apply';

  @override
  String get description =>
      'Rewrite tr() literals that source review corrected (update-your-code).';

  @override
  Future<int> run() async {
    final results = argResults!;
    final configPath =
        globalResults?['config'] as String? ?? Easyi18nConfig.fileName;
    final config = Easyi18nConfig.load(File(configPath), logger: _logger);
    final write = results['write'] as bool;

    final token = requireCredential(
      token: results['token'] as String?, environment: _environment,
      baseUrl: config.baseUrl,
      need: 'Create an API key in your project settings (needs the read scope).',
    );

    final sourceDir = results['source-dir'] as String;
    final plan = await _runner.plan(
      config: config, configPath: configPath, token: token, logger: _logger,
      sourceDir: sourceDir,
      apiClientFactory: _apiClientFactory,
    );
    _reportPlan(plan, sourceDir, write: write);
    final result = _runner.apply(plan, write: write);
    if (write && !plan.rewrites.isEmpty) {
      _logger.info(
        '\nUpdated ${plan.rewrites.edits.length} call site(s) across ${result.filesChanged} '
        "file(s). Review the diff, then run 'easyi18n push' — the entries "
        'reconcile automatically on the next push.',
      );
    }
    if (output.json) output.emit(result.toJson());
    return 0;
  }

  void _reportPlan(ApplyPlan result, String sourceDir, {required bool write}) {
    final plan = result.rewrites;
    if (result.pendingCount == 0) {
      _logger.info('No pending code changes. Nothing to apply.');
      return;
    }

    if (plan.isEmpty) {
      _logger.info(
        '${result.pendingCount} pending code change(s), but no matching tr() '
        'call site was found in $sourceDir/.',
      );
      _reportUnmatched(plan);
      return;
    }

    _logger.info(
      '${plan.edits.length} call site(s) to update '
      '(${plan.filesScanned} file(s) scanned):',
    );
    for (final e in plan.edits) {
      _logger.info('  ${e.file}:${e.line}');
      _logger.detail("tr('${e.oldSource}') -> tr('${e.newSource}')");
    }
    _reportUnmatched(plan);

    if (!write) {
      _logger.info('\nPreview only. Re-run with --write to apply.');
    }
  }

  void _reportUnmatched(RewritePlan plan) {
    if (plan.unmatched.isEmpty) return;
    _logger.warn(
      '${plan.unmatched.length} change(s) had no matching literal (already '
      'updated, or the call uses a variable/interpolation):',
    );
    for (final c in plan.unmatched) {
      _logger.detail(
        "tr('${c.oldSource}')${c.ctx != null ? ' ctx:${c.ctx}' : ''}",
      );
    }
  }

}
