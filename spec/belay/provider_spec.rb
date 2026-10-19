# frozen_string_literal: true

RSpec.describe Belay::Provider do
  it "raises NotImplementedError when #call isn't overridden by a subclass" do
    provider = described_class.new

    expect { provider.call(model: "x", prompt: "y") }.to raise_error(NotImplementedError, /#{described_class}/)
  end

  it "names the actual subclass in the error, not always Belay::Provider" do
    # Assigning an anonymous class to a constant gives it a real #name - a bare
    # Class.new(described_class) would stay anonymous and defeat this test.
    stub_const("ForgetfulProvider", Class.new(described_class))

    expect { ForgetfulProvider.new.call(model: "x", prompt: "y") }
      .to raise_error(NotImplementedError, /ForgetfulProvider/)
  end

  it "lets a subclass override #call and return a Belay::ProviderResponse" do
    subclass = Class.new(described_class) do
      # Keeping schema: in the signature (even unused) matches the real interface - a
      # subclass that doesn't need it shouldn't have to omit it from its override.
      def call(model:, prompt:, schema: nil) # rubocop:disable Lint/UnusedMethodArgument
        Belay::ProviderResponse.new(content: prompt.upcase, model: model)
      end
    end

    response = subclass.new.call(model: "fake-model", prompt: "hi")

    expect(response).to be_a(Belay::ProviderResponse)
    expect(response.content).to eq("HI")
    expect(response.model).to eq("fake-model")
  end
end
