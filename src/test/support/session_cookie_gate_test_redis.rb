# frozen_string_literal: true

# In-memory stand-in for the subset of Redis used by SessionCookieGate (no REDIS_URL required).
class SessionCookieGateTestRedis
  def initialize
    @strings = {}
  end

  def exists(key)
    @strings.key?(key.to_s) ? 1 : 0
  end

  def set(key, val)
    @strings[key.to_s] = val.to_s
    "OK"
  end

  def setex(key, _ttl_seconds, val)
    set(key, val)
  end

  def get(key)
    @strings[key.to_s]
  end

  def del(*keys)
    keys.flatten.count { @strings.delete(it.to_s) }
  end

  def eval(_script, keys:, argv:)
    strikes_key = keys.fetch(0)
    tick_key = keys.fetch(1)
    now = argv.fetch(0).to_f
    gap = argv.fetch(1).to_f
    _ttl = argv.fetch(2).to_i

    last = (@strings[tick_key.to_s] || '0').to_f
    if last == 0.0 || ((now - last) >= gap)
      cur = (@strings[strikes_key.to_s] || '0').to_i + 1
      @strings[strikes_key.to_s] = cur.to_s
      @strings[tick_key.to_s] = now.to_s
      cur
    else
      (@strings[strikes_key.to_s] || '0').to_i
    end
  end

  def multi
    batch = RedisMultiBatch.new(@strings)
    yield batch
    batch.results
  end

  class RedisMultiBatch
    def initialize(store)
      @store = store
      @results = []
    end

    attr_reader :results

    def incr(key)
      k = key.to_s
      cur = (@store[k] || "0").to_i + 1
      @store[k] = cur.to_s
      @results << cur
    end

    def expire(_key, _seconds)
      @results << true
    end
  end
end
