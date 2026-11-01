import 'cli_output.dart' show sanitizeJson;
import 'logger.dart';

/// A completed check result; presentation and JSON consume the same data.
class DoctorFinding {
  DoctorFinding({required this.check, required this.subject,
    required this.level, required this.message, List<String> details = const []})
      : details = List.unmodifiable(details);

  final String check;
  final String subject;
  final String level;
  final String message;
  final List<String> details;

  Map<String, Object?> toJson() => sanitizeJson({
    'check': check, 'subject': subject, 'level': level,
    'message': message, 'details': details,
  }) as Map<String, Object?>;
}

class DoctorReport {
  DoctorReport(Iterable<DoctorFinding> findings,
      {required this.projectDir, required this.baseUrl, required this.stack, required this.family})
      : findings = List.unmodifiable(findings);

  final String stack;
  final String family;
  final String projectDir;
  final String baseUrl;
  final List<DoctorFinding> findings;
  int get failures => findings.where((f) => f.level == 'fail').length;
  int get warnings => findings.where((f) => f.level == 'warn').length;
  int get unchecked => findings.where((f) => f.level == 'unverified').length;
  int get exitCode => failures > 0 ? 1 : 0;
  String get verdict => failures > 0 ? 'failed'
      : unchecked > 0 ? 'unverified' : warnings > 0 ? 'warnings' : 'passed';

  Map<String, Object?> toJson() => {
    'stack': CliLogger.sanitize(stack),
    'family': CliLogger.sanitize(family),
    'project_dir': CliLogger.sanitize(projectDir),
    'base_url': CliLogger.sanitize(baseUrl),
    'findings': [for (final finding in findings) finding.toJson()],
    'counts': {'failures': failures, 'warnings': warnings, 'unchecked': unchecked},
    'verdict': verdict,
  };
}

/// Shared finding construction for core and adapter checks, in replay order.
class DoctorFindings {
  DoctorFindings(this._report);
  final void Function(DoctorFinding) _report;

  void _record(String check, String level, String subject, String message,
      {List<String> details = const []}) =>
      _report(DoctorFinding(check: check, subject: subject, level: level,
          message: message, details: details));

  void ok(String check, String subject, String message,
      {List<String> details = const []}) =>
      _record(check, 'ok', subject, message, details: details);
  void skip(String check, String subject, String message,
      {List<String> details = const []}) =>
      _record(check, 'skip', subject, message, details: details);
  void unverified(String check, String subject, String message,
      {List<String> details = const []}) =>
      _record(check, 'unverified', subject, message, details: details);
  void warn(String check, String subject, String message,
      {List<String> details = const []}) =>
      _record(check, 'warn', subject, message, details: details);
  void fail(String check, String subject, String message,
      {List<String> details = const []}) =>
      _record(check, 'fail', subject, message, details: details);
}
