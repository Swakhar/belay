# frozen_string_literal: true

RSpec.describe "spec/dummy" do
  it "boots as its own Rails application, not the gem root" do
    expect(Rails.root.to_s).to eq(File.expand_path("dummy", __dir__))
  end

  it "loads config/environments/test.rb" do
    expect(Rails.application.config.cache_store).to eq(:null_store)
    expect(Rails.application.config.enable_reloading).to be false
  end

  it "has Belay loaded" do
    expect(defined?(Belay)).to eq("constant")
  end
end
