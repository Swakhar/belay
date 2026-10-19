# frozen_string_literal: true

RSpec.describe Belay::Configuration do
  subject(:configuration) { described_class.new }

  it "defaults lease_duration to 300 seconds" do
    expect(configuration.lease_duration).to eq(300)
  end

  it "defaults heartbeat_interval to 30 seconds" do
    expect(configuration.heartbeat_interval).to eq(30)
  end

  it "allows overriding each setting" do
    configuration.lease_duration = 900
    configuration.heartbeat_interval = 60

    expect(configuration.lease_duration).to eq(900)
    expect(configuration.heartbeat_interval).to eq(60)
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
