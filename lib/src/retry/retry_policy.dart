import 'dart:math';

/// Defines retry behavior and backoff parameters for transient transfer failures.
class RetryPolicy {
  /// Constructs a custom [RetryPolicy].
  const RetryPolicy({
    this.maxAttempts = 3,
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.backoffMultiplier = 2.0,
    this.useJitter = true,
    this.allowRetry = true,
  }) : assert(maxAttempts > 0, 'maxAttempts must be greater than 0'),
       assert(
         backoffMultiplier >= 1.0,
         'backoffMultiplier must be at least 1.0',
       );

  /// Fail-fast policy: zero retries.
  ///
  /// Fails immediately on any error so the application can block or prompt the user to manually re-upload.
  static const RetryPolicy none = RetryPolicy(
    maxAttempts: 1,
    allowRetry: false,
  );

  /// Standard retry policy with exponential backoff and jitter.
  ///
  /// Retries transient failures up to [maxAttempts] (default 3).
  static const RetryPolicy standard = RetryPolicy(
    maxAttempts: 3,
    initialDelay: Duration(seconds: 1),
    maxDelay: Duration(seconds: 30),
    backoffMultiplier: 2.0,
    useJitter: true,
    allowRetry: true,
  );

  /// Whether automatic retries are permitted.
  ///
  /// If `false`, transfers fail immediately on the first error.
  final bool allowRetry;

  /// Maximum number of attempts allowed (including the initial attempt).
  final int maxAttempts;

  /// Initial delay before the first retry attempt.
  final Duration initialDelay;

  /// Maximum ceiling delay between retry attempts.
  final Duration maxDelay;

  /// Multiplier applied to the delay on each consecutive attempt.
  final double backoffMultiplier;

  /// Whether to apply full jitter to randomize backoff delays and avoid thundering herds.
  final bool useJitter;

  /// Calculates the backoff delay for the given [attempt] number (1-based).
  Duration calculateDelay(int attempt, [Random? random]) {
    if (!allowRetry || attempt >= maxAttempts) {
      return Duration.zero;
    }

    final rand = random ?? Random();
    final factor = pow(backoffMultiplier, attempt - 1).toDouble();
    final calculatedMs = (initialDelay.inMilliseconds * factor).round();
    final ceilingMs = min(calculatedMs, maxDelay.inMilliseconds);

    if (useJitter) {
      final jitteredMs = ceilingMs > 0 ? rand.nextInt(ceilingMs + 1) : 0;
      return Duration(milliseconds: jitteredMs);
    } else {
      return Duration(milliseconds: ceilingMs);
    }
  }
}
