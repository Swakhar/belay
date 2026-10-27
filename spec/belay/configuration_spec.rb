# frozen_string_literal: true

RSpec.describe Belay::Configuration do
  subject(:configuration) { described_class.new }

  it "defaults lease_duration to 300 seconds" do
    expect(configuration.lease_duration).to eq(300)
  end

  it "defaults heartbeat_interval to 30 seconds" do
    expect(configuration.heartbeat_interval).to eq(30)
  end

  it "defaults provider to nil" do
    expect(configuration.provider).to be_nil
  end

  it "defaults cache_ttl to 7 days" do
    expect(configuration.cache_ttl).to eq(7 * 24 * 60 * 60)
  end

  it "defaults rule_approval_threshold to 3" do
    expect(configuration.rule_approval_threshold).to eq(3)
  end

  it "defaults custom_css to nil" do
    expect(configuration.custom_css).to be_nil
  end

  it "allows overriding each setting" do
    provider = Belay::FakeProvider.new
    configuration.lease_duration = 900
    configuration.heartbeat_interval = 60
    configuration.provider = provider
    configuration.cache_ttl = nil
    configuration.rule_approval_threshold = 5
    configuration.custom_css = ".btn-primary { background: #000 }"

    expect(configuration.lease_duration).to eq(900)
    expect(configuration.heartbeat_interval).to eq(60)
    expect(configuration.provider).to equal(provider)
    expect(configuration.cache_ttl).to be_nil
    expect(configuration.rule_approval_threshold).to eq(5)
    expect(configuration.custom_css).to eq(".btn-primary { background: #000 }")
  end
end

RSpec.describe Belay do
  it ".config memoizes a single Configuration instance" do
    expect(described_class.config).to be_a(Belay::Configuration)
    expect(described_class.config).to equal(described_class.config)
  end

  it ".configure yields the memoized config for mutation" do
    described_class.configure { |config| config.lease_duration = 900 }

    expect(described_class.config.lease_duration).to eq(900)
  end

  it ".reset_config! clears the memo so the next read builds a fresh default" do
    described_class.configure { |config| config.lease_duration = 900 }
    described_class.reset_config!

    expect(described_class.config.lease_duration).to eq(300)
  end
end
