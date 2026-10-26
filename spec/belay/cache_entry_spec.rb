# frozen_string_literal: true

RSpec.describe Belay::CacheEntry do
  def provider
    @provider ||= Belay::FakeProvider.new
  end

  # A genuinely different PROVIDER CLASS, not just another FakeProvider
  # instance - key_for hashes provider.class.name, so two FakeProvider
  # instances are indistinguishable to it by design (same reasoning any
  # future FakeProvider instance should hit the same cache a prior one
  # filled - this is the single process-wide cache, not per-instance).
  def another_provider_class
    @another_provider_class ||= Class.new(Belay::Provider) do
      def call(**)
        Belay::ProviderResponse.new(content: "x")
      end
    end.new
  end

  describe ".key_for" do
    it "is the same for identical calls" do
      a = described_class.key_for(provider: provider, model: "x", prompt: "hi", schema: nil)
      b = described_class.key_for(provider: provider, model: "x", prompt: "hi", schema: nil)

      expect(a).to eq(b)
    end

    it "differs on model, prompt, or schema" do
      base = described_class.key_for(provider: provider, model: "x", prompt: "hi", schema: nil)

      expect(described_class.key_for(provider: provider, model: "y", prompt: "hi", schema: nil)).not_to eq(base)
      expect(described_class.key_for(provider: provider, model: "x", prompt: "bye", schema: nil)).not_to eq(base)
      expect(described_class.key_for(provider: provider, model: "x", prompt: "hi", schema: { a: 1 })).not_to eq(base)
    end

    it "differs on provider CLASS, even with everything else identical - a cache entry from one " \
       "provider should never satisfy another's lookup" do
      a = described_class.key_for(provider: provider, model: "x", prompt: "hi", schema: nil)
      b = described_class.key_for(provider: another_provider_class, model: "x", prompt: "hi", schema: nil)

      expect(a).not_to eq(b)
    end

    it "does not normalize symbol vs string keys - exact-match means exact, not semantically equivalent" do
      symbol_keyed = described_class.key_for(provider: provider, model: "x", prompt: "hi", schema: { a: 1 })
      string_keyed = described_class.key_for(provider: provider, model: "x", prompt: "hi", schema: { "a" => 1 })

      expect(symbol_keyed).not_to eq(string_keyed)
    end
  end

  describe ".fetch / .store!" do
    it "is nil before anything has been stored for this key" do
      expect(described_class.fetch(provider: provider, model: "x", prompt: "hi", schema: nil)).to be_nil
    end

    it "returns what was stored for the exact same call" do
      described_class.store!(provider: provider, model: "x", prompt: "hi", schema: nil, content: { "a" => 1 })

      expect(described_class.fetch(provider: provider, model: "x", prompt: "hi", schema: nil)).to eq("a" => 1)
    end

    it "is nil for a call that differs in any way from what was stored" do
      described_class.store!(provider: provider, model: "x", prompt: "hi", schema: nil, content: "cached")

      expect(described_class.fetch(provider: provider, model: "y", prompt: "hi", schema: nil)).to be_nil
    end

    it "increments hits on every real fetch, not on a miss" do
      described_class.store!(provider: provider, model: "x", prompt: "hi", schema: nil, content: "cached")

      2.times { described_class.fetch(provider: provider, model: "x", prompt: "hi", schema: nil) }
      described_class.fetch(provider: provider, model: "y", prompt: "hi", schema: nil) # a miss

      entry = described_class.sole
      expect(entry.hits).to eq(2)
    end

    it "treats an expired entry as a miss, without deleting the row" do
      described_class.store!(provider: provider, model: "x", prompt: "hi", schema: nil, content: "cached", ttl: -1)

      result = described_class.fetch(provider: provider, model: "x", prompt: "hi", schema: nil)

      expect(result).to be_nil
      expect(described_class.count).to eq(1) # the row is still there, just expired
    end

    it "never expires when ttl: is nil" do
      described_class.store!(provider: provider, model: "x", prompt: "hi", schema: nil, content: "cached", ttl: nil)

      expect(described_class.fetch(provider: provider, model: "x", prompt: "hi", schema: nil)).to eq("cached")
    end

    it "defaults ttl: to the current Belay.config.cache_ttl, read fresh at store time" do
      Belay.configure { |c| c.cache_ttl = -1 } # already expired the moment it's stored

      described_class.store!(provider: provider, model: "x", prompt: "hi", schema: nil, content: "cached")

      expect(described_class.fetch(provider: provider, model: "x", prompt: "hi", schema: nil)).to be_nil
      Belay.reset_config!
    end

    it "overwrites an existing entry for the same key, resetting hits, rather than raising on the unique index" do
      described_class.store!(provider: provider, model: "x", prompt: "hi", schema: nil, content: "first")
      described_class.fetch(provider: provider, model: "x", prompt: "hi", schema: nil)

      described_class.store!(provider: provider, model: "x", prompt: "hi", schema: nil, content: "second")

      expect(described_class.count).to eq(1)
      entry = described_class.sole
      expect(entry.content).to eq("second")
      expect(entry.hits).to eq(0)
    end
  end
end
