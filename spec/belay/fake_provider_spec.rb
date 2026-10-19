# frozen_string_literal: true

RSpec.describe Belay::FakeProvider do
  it "is a real Belay::Provider" do
    expect(described_class.new).to be_a(Belay::Provider)
  end

  describe "scripted responses" do
    it "returns a plain string entry auto-wrapped as a ProviderResponse, using the call's own model" do
      provider = described_class.new(responses: ["hello"])

      response = provider.call(model: "fake-model", prompt: "hi")

      expect(response).to be_a(Belay::ProviderResponse)
      expect(response.content).to eq("hello")
      expect(response.model).to eq("fake-model")
    end

    it "returns a literal ProviderResponse entry as-is, untouched" do
      scripted = Belay::ProviderResponse.new(content: "exact", model: "claude-sonnet-4-6", input_tokens: 10)
      provider = described_class.new(responses: [scripted])

      expect(provider.call(model: "whatever-the-call-asks-for", prompt: "hi")).to equal(scripted)
    end

    it "returns each scripted response in order, one per call" do
      provider = described_class.new(responses: %w[first second third])

      expect(provider.call(model: "m", prompt: "a").content).to eq("first")
      expect(provider.call(model: "m", prompt: "b").content).to eq("second")
      expect(provider.call(model: "m", prompt: "c").content).to eq("third")
    end

    it "allows mixing literal ProviderResponse and plain entries in the same queue" do
      literal = Belay::ProviderResponse.new(content: "exact", model: "claude-sonnet-4-6")
      provider = described_class.new(responses: [literal, "auto-wrapped"])

      first = provider.call(model: "m", prompt: "a")
      second = provider.call(model: "m", prompt: "b")

      expect(first).to equal(literal)
      expect(second.content).to eq("auto-wrapped")
      expect(second.model).to eq("m")
    end

    it "raises when the script runs out, rather than repeating the last response" do
      provider = described_class.new(responses: ["only one"])
      provider.call(model: "m", prompt: "a")

      expect { provider.call(model: "m", prompt: "b") }
        .to raise_error(Belay::FakeProvider::ScriptExhaustedError, /no scripted response left/)
    end

    it "is a Belay::Error subclass, catchable generically" do
      expect(Belay::FakeProvider::ScriptExhaustedError.ancestors).to include(Belay::Error)
    end
  end

  describe "#calls" do
    it "records what every call actually received, in order" do
      provider = described_class.new(responses: %w[a b])

      provider.call(model: "m1", prompt: "first", schema: "S1")
      provider.call(model: "m2", prompt: "second")

      expected = [
        { model: "m1", prompt: "first", schema: "S1" },
        { model: "m2", prompt: "second", schema: nil }
      ]
      expect(provider.calls).to eq(expected)
    end

    it "is empty before any call is made" do
      expect(described_class.new.calls).to eq([])
    end

    it "returns a frozen array, so a spec can't mutate the provider's own record of calls" do
      provider = described_class.new(responses: ["a"])
      provider.call(model: "m", prompt: "a")

      expect { provider.calls << { model: "sneaked_in", prompt: "x", schema: nil } }.to raise_error(FrozenError)
      expect(provider.calls.size).to eq(1)
    end
  end
end
