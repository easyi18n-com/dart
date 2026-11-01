/// easyi18n - runtime SDK.
///
/// Wrap your `MaterialApp` with [Easyi18nScope] and translate with
/// `context.tr('Welcome {name}', args: {'name': n})`. Strings resolve from an
/// offline floor (baked assets) and hot-update from the delivery manifest with
/// no extra code. See the README for setup.
library;

export 'src/delivery/bundle_store.dart'
    show BundleStore, InMemoryBundleStore, LazyBundleStore, DeliveryState;
export 'src/delivery/cdn_client.dart' show CdnClient, DeliveryException;
export 'src/delivery/delivery_service.dart' show DeliveryService, RefreshResult;
export 'src/delivery/file_bundle_store.dart' show FileBundleStore;
export 'src/flutter/controller.dart' show Easyi18nController, BakedLoader;
export 'src/flutter/extensions.dart' show Easyi18nContext, Easyi18nString;
export 'src/flutter/scope.dart'
    show Easyi18nScope, kDefaultBaseUrl, localeFromTag;
