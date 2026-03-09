export function createLogger() {
  function emit(level, event, metadata = {}) {
    const payload = {
      level,
      event,
      metadata,
      timestamp: new Date().toISOString()
    };
    const line = JSON.stringify(payload);
    if (level === 'error') {
      console.error(line);
      return;
    }
    console.log(line);
  }

  return {
    info(event, metadata) {
      emit('info', event, metadata);
    },
    warn(event, metadata) {
      emit('warn', event, metadata);
    },
    error(event, metadata) {
      emit('error', event, metadata);
    }
  };
}

export function createInMemoryRateLimiter(limitPerMinute) {
  const buckets = new Map();
  const durationMs = 60_000;

  return function rateLimit(key) {
    const now = Date.now();
    const value = buckets.get(key) || { count: 0, resetAt: now + durationMs };

    if (value.resetAt <= now) {
      value.count = 0;
      value.resetAt = now + durationMs;
    }

    value.count += 1;
    buckets.set(key, value);

    return {
      allowed: value.count <= limitPerMinute,
      retryAfterSeconds: Math.max(1, Math.ceil((value.resetAt - now) / 1000))
    };
  };
}
