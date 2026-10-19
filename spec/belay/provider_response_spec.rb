# frozen_string_literal: true

RSpec.describe Belay::ProviderResponse do
  def build_response(**overrides)
    described_class.new(content: "hello", model: "claude-sonnet-4-6", **overrides)
  end

  it "requires content" do
    expect { described_class.new(model: "claude-sonnet-4-6") }.to raise_error(ArgumentError, /content/)
  end

  it "requires model" do
    expect { described_class.new(content: "hello") }.to raise_error(ArgumentError, /model/)
  end

  it "allows content to be falsy but present (false, 0, empty string), not just truthy" do
    expect(build_response(content: false).content).to eq(false)
    expect(build_response(content: 0).content).to eq(0)
    expect(build_response(content: "").content).to eq("")
  end

  it "defaults token/cost/latency fields to nil - not every provider call has them" do
    response = build_response

    expect(response.input_tokens).to be_nil
    expect(response.output_tokens).to be_nil
    expect(response.cost_cents).to be_nil
    expect(response.latency_ms).to be_nil
  end

  it "accepts token/cost/latency when the provider supplies them" do
    response = build_response(input_tokens: 120, output_tokens: 45, cost_cents: 3, latency_ms: 850)

    expect(response.input_tokens).to eq(120)
    expect(response.output_tokens).to eq(45)
    expect(response.cost_cents).to eq(3)
    expect(response.latency_ms).to eq(850)
  end

  it "is frozen, so a caller can't mutate a response after the fact" do
    expect { build_response.content = "changed" }.to raise_error(FrozenError)
  end
end
