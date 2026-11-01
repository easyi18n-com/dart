/// Programmatic entry point for the easyi18n CLI.
///
/// Most users run the bundled `easyi18n` executable; this library exposes the
/// same command set so you can embed it in your own Dart tooling:
///
/// ```dart
/// import 'package:easyi18n_cli/easyi18n_cli.dart';
///
/// Future<void> main(List<String> args) =>
///     Easyi18nCommandRunner().run(args);
/// ```
library;

export 'src/adapters/android_adapter.dart' show AndroidAdapter;
export 'src/adapters/dart_flutter_adapter.dart' show DartFlutterAdapter;
export 'src/adapters/xcstrings_adapter.dart' show XcstringsAdapter;
export 'src/apply_runner.dart' show ApplyRunner, ApplyPlan, ApplyResult;
export 'src/cli_output.dart' show CliOutput, JsonPresenter;
export 'src/command_runner.dart' show Easyi18nCommandRunner;
export 'src/doctor_runner.dart'
    show DoctorRunner, DoctorReport, DoctorFinding, DeliveryClientFactory;
export 'src/exceptions.dart' show CliException;
export 'src/extract_runner.dart' show ExtractRunner, ExtractResult;
export 'src/init_runner.dart' show InitRunner, InitReport, InitStep;
export 'src/languages_runner.dart' show LanguageAddRunner, LanguageAddResult;
export 'src/logger.dart' show CliLogger;
export 'src/output_format.dart' show OutputFormatRunner, OutputFormatResult;
export 'src/pull_runner.dart' show PullRunner, PullOutcome;
export 'src/push_runner.dart'
    show PushRunner, PushScan, PushPreview, PushReport, PushResult;
export 'src/rollback_runner.dart' show RollbackRunner, RollbackResult;
export 'src/session.dart' show requireToken, withProject;
export 'src/status_runner.dart' show StatusRunner, StatusResult;
export 'src/sync_runner.dart'
    show
        SyncRunner,
        SyncScan,
        SyncPreview,
        SyncOutcome,
        SyncRunProgress,
        SyncDelivery,
        SyncReport,
        CatalogLanguageGaps;
export 'src/version.dart' show packageVersion;
