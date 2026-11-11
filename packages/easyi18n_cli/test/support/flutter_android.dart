import 'dart:io';

import 'package:path/path.dart' as p;

const kMainManifest = 'android/app/src/main/AndroidManifest.xml';
const kReleaseManifest = 'android/app/src/release/AndroidManifest.xml';
const kInternetLine =
    '<uses-permission android:name="android.permission.INTERNET" />';

/// The Android half of a `flutter create` app under [root]: the main manifest
/// without INTERNET, which the template declares for debug runs only, behind
/// a comment that names it too (#2340). [mainExtra] lands before
/// `<application`; [release] is written as the release source set's manifest.
void writeFlutterAndroid(String root, {String mainExtra = '', String? release}) {
  File write(String relative) =>
      File(p.join(root, relative))..createSync(recursive: true);
  write(kMainManifest).writeAsStringSync('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
$mainExtra    <application
        android:label="demo_app"
        android:name="\${applicationName}"
        android:icon="@mipmap/ic_launcher">
        <activity android:name=".MainActivity" android:exported="true" />
    </application>
</manifest>
''');
  write('android/app/src/debug/AndroidManifest.xml').writeAsStringSync('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- The INTERNET permission is required for development. Specifically,
         the Flutter tool needs it to communicate with the running application.
    -->
    <uses-permission android:name="android.permission.INTERNET"/>
</manifest>
''');
  if (release != null) write(kReleaseManifest).writeAsStringSync(release);
}
