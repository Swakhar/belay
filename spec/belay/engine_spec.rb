# frozen_string_literal: true

# Real HTTP-level tests, not controller unit tests: spec/dummy mounts
# Belay::Engine at /belay in its own config/routes.rb (mirroring exactly what
# the README tells a host app to do), so these requests travel through Rails'
# actual router, middleware stack and the engine's own routes.rb-equivalent
# (lib/belay/engine.rb) - proving the mount and the authentication hook both
# really work, not just that the classes are shaped correctly.
RSpec.describe Belay::Engine do
  after { Belay.reset_config! }

  def get(path)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.get(path)
    session
  end

  it "is an isolated Rails::Engine, not just a plain Rails::Engine subclass" do
    expect(described_class.superclass).to eq(Rails::Engine)
    expect(described_class.isolated?).to be true
  end

  it "raises a clear error if authenticate_with was never configured, rather than serving the dashboard open" do
    expect { get("/belay/") }.to raise_error(Belay::Error, /authenticate_with/)
  end

  it "returns 401 when the configured authenticator returns false" do
    Belay.configure { |c| c.authenticate_with = ->(_request) { false } }

    session = get("/belay/")

    expect(session.response.status).to eq(401)
  end

  it "serves the request when the configured authenticator returns true" do
    Belay.configure { |c| c.authenticate_with = ->(_request) { true } }

    session = get("/belay/")

    expect(session.response.status).to eq(200)
  end

  it "renders the shared navbar on every page, linking back to the runs index" do
    Belay.configure { |c| c.authenticate_with = ->(_request) { true } }

    session = get("/belay/")

    doc = Nokogiri::HTML(session.response.body)
    expect(doc.css("header a").map { |a| a["href"] }).to include("/belay/runs")
  end

  it "passes the real ActionDispatch::Request to the authenticator, not a stand-in" do
    received = nil
    Belay.configure do |c|
      c.authenticate_with = lambda { |request|
        received = request
        true
      }
    end

    get("/belay/")

    expect(received).to be_a(ActionDispatch::Request)
  end

  describe ".stylesheet" do
    it "reads the committed, precompiled Tailwind build - not empty, not CSS source syntax" do
      css = described_class.stylesheet

      expect(css).not_to be_empty
      expect(css).not_to include("@tailwind") # the SOURCE file's directives - this is the compiled output
    end

    it "is inlined into every rendered page, not linked" do
      Belay.configure { |c| c.authenticate_with = ->(_request) { true } }

      session = get("/belay/")

      expect(session.response.body).to include("<style>#{described_class.stylesheet}</style>")
    end
  end
end
