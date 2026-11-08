import 'dart:async';

import 'package:chopper/chopper.dart';
import 'package:finamp/services/chopper_aggregate_logger.dart';

final aggregateLogger = ChopperAggregateLogger();

/// A HttpLoggingInterceptor that aggregates the request and
/// response logs from Chopper, using the [ChopperAggregateLogger].
class HttpAggregateLoggingInterceptor extends HttpLoggingInterceptor {
  HttpAggregateLoggingInterceptor({super.level = Level.body, Duration burstQuietAfter = const Duration(seconds: 10)})
    : _playlistLoads = RequestBurst(report: aggregateLogger.info, quietAfter: burstQuietAfter),
      super(logger: aggregateLogger);

  final RequestBurst _playlistLoads;

  static final _playlistItems = RegExp(r'/Playlists/[^/]+/Items$');

  @override
  FutureOr<Response<BodyType>> intercept<BodyType>(Chain<BodyType> chain) async {
    aggregateLogger.onStartRequest(chain.request);
    final took = Stopwatch()..start();
    final Response<BodyType> response = await super.intercept(HttpAggregateLoggingChain(chain));
    // Only successes are thinned out: a failed request always shows in full.
    final leaveOut =
        response.isSuccessful &&
        chain.request.method == HttpMethod.Get &&
        _playlistItems.hasMatch(chain.request.url.path) &&
        _playlistLoads.leaveOut(took.elapsedMilliseconds);
    // Request info isn't printed until after response completes
    aggregateLogger.onEndRequest(chain.request, leaveOut: leaveOut);
    aggregateLogger.onEndResponse(response, leaveOut: leaveOut);
    return response;
  }
}

class HttpAggregateLoggingChain<T> implements Chain<T> {
  HttpAggregateLoggingChain(this._chain);

  final Chain<T> _chain;

  @override
  FutureOr<Response<T>> proceed(Request request) async {
    var response = await _chain.proceed(request);
    aggregateLogger.onStartResponse(response);
    return response;
  }

  @override
  Request get request => _chain.request;
}
