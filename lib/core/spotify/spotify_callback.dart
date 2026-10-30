import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

const _channel = MethodChannel('classipod/spotify_auth');

/// Opens [url] in a Custom Tab and completes with the redirect URL that
/// MainActivity receives. Returning to the app without a redirect cancels.
Future<String> authenticateInBrowser(String url, String scheme) async {
  final result = Completer<String>();
  void complete(Object? value) {
    if (value is String &&
        value.startsWith('$scheme:') &&
        !result.isCompleted) {
      result.complete(value);
    }
  }

  _channel.setMethodCallHandler((call) async {
    if (call.method == 'callback') complete(call.arguments);
  });
  final lifecycle = AppLifecycleListener(
    onResume: () async {
      complete(await _channel.invokeMethod<String>('takeCallback'));
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!result.isCompleted) {
        result.completeError(PlatformException(code: 'CANCELED'));
      }
    },
  );
  try {
    if (!await launchUrl(Uri.parse(url), mode: LaunchMode.inAppBrowserView)) {
      throw PlatformException(code: 'LAUNCH_FAILED');
    }
    return await result.future;
  } finally {
    lifecycle.dispose();
    _channel.setMethodCallHandler(null);
  }
}
