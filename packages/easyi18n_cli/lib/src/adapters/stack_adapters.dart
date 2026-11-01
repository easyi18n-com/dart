import '../config.dart';
import '../delivery.dart' show DeliveryClientFactory;
import '../exceptions.dart';
import '../extract/tr_extractor.dart';
import 'android_adapter.dart';
import 'dart_flutter_adapter.dart';
import 'stack_adapter.dart';
import 'web_adapter.dart';
import 'xcstrings_adapter.dart';

/// Preserve the historical CLI default: a stack nobody named is Flutter.
const defaultStack = 'flutter';
const supportedStacks = [defaultStack, 'xcode', 'web', 'android'];

/// What a repository outside [supportedStacks] is told is coming. The `setup`
/// prompt and the refusals below read this one constant: a client that does
/// not load MCP prompts (Codex) sees only the refusal (#1930).
const stackRoadmap = 'web t() extraction, gettext';

/// [stackRoadmap] one stack per entry, for a caller that reads fields. Split
/// from the sentence form because `setupPrompt` is a `const` and can only
/// interpolate a constant string.
List<String> get roadmapStacks => stackRoadmap.split(', ');

/// Detection order, and the order `auto` tries: Flutter first, because every
/// Flutter app ships `ios/Runner.xcodeproj` and would otherwise be claimed by
/// the Xcode adapter the day it grows a catalog, and `android/` with its
/// Gradle scripts and `res/values/strings.xml` would be claimed by Android.
/// Web before Android: React Native and Capacitor apps commit that same
/// `android/` with a template `strings.xml`, and Web claims a tree only when
/// `package.json` declares one of its i18n libraries (#2311).
List<StackAdapter> _adapters(
        {TrExtractor? extractor, DeliveryClientFactory? deliveryFactory}) =>
    <StackAdapter>[
      DartFlutterAdapter(extractor: extractor, deliveryFactory: deliveryFactory),
      const XcstringsAdapter(),
      const WebAdapter(),
      const AndroidAdapter(),
    ];

/// [forAgent] is set by the MCP. An agent may name a stack the tree does not
/// have, while whoever types `--stack` knows the repository, so a named stack
/// is held to detection too (#2444). And an agent asked to set easyi18n up
/// reads what detection needs as the next step: in corrida 9 Codex installed
/// i18next. Its refusal says to stop and tell the human instead (#2470).
StackAdapter selectStackAdapter(String root, {String stack = defaultStack,
    bool forAgent = false, TrExtractor? extractor,
    DeliveryClientFactory? deliveryFactory}) {
  if (stack != 'auto' && !supportedStacks.contains(stack)) {
    throw CliException('Unknown stack "$stack". Supported: '
        '${[...supportedStacks, 'auto'].join(', ')}; roadmap: $stackRoadmap.');
  }
  final adapters =
      _adapters(extractor: extractor, deliveryFactory: deliveryFactory);
  for (final adapter in adapters) {
    if (stack == adapter.stack) {
      if (!forAgent || adapter.detect(root)) return adapter;
      final detected = [for (final a in adapters) if (a.detect(root)) a.stack];
      if (detected.isEmpty) {
        throw _stopHere('No $stack project found at $root');
      }
      throw _unsupportedStack('No $stack project found at $root '
          '(detected there: ${detected.join(', ')}). $_stackLists Call init '
          'again with one of the detected stacks or with stack auto.');
    }
    if (stack == 'auto' && adapter.detect(root)) return adapter;
  }
  if (forAgent) throw _stopHere('No supported stack found at $root');
  throw _unsupportedStack('No supported stack found at $root '
      '(web needs ${const WebAdapter().detectionNeeds}). $_stackLists');
}

String get _stackLists =>
    'Supported: ${supportedStacks.join(', ')}; roadmap: $stackRoadmap.';

/// The lists sit inside what the human is told: asked to tell them "with the
/// roadmap", Codex named the supported stacks and left the roadmap out.
CliException _stopHere(String finding) => _unsupportedStack('$finding. If '
    'the app is in a subdirectory, call init again with project_dir set to '
    'it. Otherwise do not add dependencies or files to make init accept this '
    'repository, and tell the human: "easyi18n does not support this '
    'repository yet. $_stackLists"');

CliException _unsupportedStack(String message) => CliException(message,
    code: 'unsupported_stack',
    details: {'supported': supportedStacks, 'roadmap': roadmapStacks});

/// The adapter to GRADE [root] with, for a caller that writes nothing: the
/// detected stack, then the one the config declares (if there is one yet),
/// then [defaultStack].
///
/// Deliberately unlike `--stack auto`, which refuses a tree it cannot place
/// rather than scaffolding the wrong stack into it. `doctor` has nothing to
/// scaffold and every reason to answer: refusing would take away the command
/// a dev runs precisely because they do not know what is wrong.
///
/// The config is consulted only after detection fails, and what it reads is
/// the FORMAT: a format that renders every language into one file is a
/// file-first project wherever the checkout came from (a CI clone without the
/// `.xcodeproj`, a catalog owned by a non-Xcode tool). A Flutter project that
/// also syncs a catalog still grades as Flutter: detection ran first.
///
/// Keyed on the format and not on `catalog:` on purpose. The project that most
/// needs these checks is the one `init` could not finish — `format: xcstrings`
/// written, no catalog found — and a fallback that required `catalog:` graded
/// exactly that project as Flutter, burying the one finding that names what is
/// missing under runtime-wiring failures it can never satisfy.
///
/// One exception: a web app that commits `android/` and chose
/// `init --stack android` declares `android_xml`. Web is what detects, but its
/// checks would fail the base `strings.xml` as not JSON, so the format sends
/// it to Android.
StackAdapter adapterFor(String root, Easyi18nConfig? config,
    {TrExtractor? extractor, DeliveryClientFactory? deliveryFactory}) {
  final adapters =
      _adapters(extractor: extractor, deliveryFactory: deliveryFactory);
  for (final adapter in adapters) {
    if (!adapter.detect(root)) continue;
    if (adapter is WebAdapter && config?.format == kAndroidFormat) break;
    return adapter;
  }
  if (config == null) return adapters.first;
  if (config.format == kAndroidFormat) {
    return adapters.whereType<AndroidAdapter>().first;
  }
  if (config.source != null && !config.sourceIsArbTemplate) {
    return adapters.whereType<WebAdapter>().first;
  }
  if (Easyi18nConfig.catalogFormats.contains(config.format)) {
    return adapters.firstWhere((a) => a.family == 'file-first',
        orElse: () => adapters.first);
  }
  return adapters.first;
}
