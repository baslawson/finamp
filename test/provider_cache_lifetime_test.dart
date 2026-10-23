import 'package:finamp/utils/provider_cache_lifetime.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a long artwork session releases inactive cached providers while retaining the visible one', (
    tester,
  ) async {
    final disposed = <int>[];
    final provider = Provider.autoDispose.family<Object, int>((ref, id) {
      cacheProviderBriefly(ref);
      ref.onDispose(() => disposed.add(id));
      return Object();
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final subscriptions = List.generate(300, (i) => container.listen(provider(i), (_, _) {}));
    final recent = container.read(provider(0));
    for (final subscription in subscriptions.take(299)) {
      subscription.close();
    }
    await tester.pump();
    expect(disposed, isEmpty);
    expect(container.read(provider(0)), same(recent));
    await tester.pump(const Duration(seconds: 61));
    await tester.pump();
    expect(disposed, hasLength(299));
    expect(disposed, isNot(contains(299)));
    subscriptions.last.close();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(disposed, hasLength(300));
  });
}
