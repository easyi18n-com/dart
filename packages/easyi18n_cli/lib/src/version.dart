/// The version of this package, pinned by hand.
///
/// It has to be a compiled-in constant rather than a read of `pubspec.yaml`: a
/// binary installed with `dart pub global activate` runs from the pub cache
/// with no pubspec beside it, and a `dart compile exe` build has no package
/// layout at all. So the version travels *inside* the code, and the thing that
/// keeps it honest lives in the suite - `test/version_test.dart` compares this
/// constant against the `version:` the pubspec declares.
///
/// That guard is the point. A hand-maintained constant drifts on the first
/// release someone bumps without touching it, and then `--version` lies, which
/// is strictly worse than having no flag: the answer looks authoritative
/// (#695).
const String packageVersion = '1.0.0';
