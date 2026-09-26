# frozen_string_literal: true

RSpec.describe Belay do
  it "has a version number" do
    expect(Belay::VERSION).to match(/\A\d+\.\d+\.\d+/)
  end
end
