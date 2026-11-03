import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Preserve short revisits without retaining every completed provider for the
/// lifetime of the app. Active listeners continue to own the provider normally.
void cacheProviderBriefly(Ref ref, [Duration duration = const Duration(minutes: 1)]) {
  final link = ref.keepAlive();
  final timer = Timer(duration, link.close);
  ref.onDispose(timer.cancel);
}
