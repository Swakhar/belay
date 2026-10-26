# frozen_string_literal: true

# Real HTTP-level tests, same philosophy as spec/belay/runs_controller_spec.rb -
# these travel through the dummy host app's actual mount, proving the real
# controller/view behavior rather than a controller-unit shortcut.
RSpec.describe Belay::StatsController do
  after { Belay.reset_config! }

  def get(path)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.get(path)
    session
  end

  def cells(session, css_class)
    Nokogiri::HTML(session.response.body).css(".#{css_class}").map(&:text)
  end

  describe "#index" do
    it "requires authentication, same as every other engine route" do
      expect { get("/belay/stats") }.to raise_error(Belay::Error, /authenticate_with/)
    end

    context "once authenticated" do
      before { Belay.configure { |c| c.authenticate_with = ->(_request) { true } } }

      it "renders an empty state with no runs at all, rather than erroring on an empty table" do
        session = get("/belay/stats")

        expect(session.response.status).to eq(200)
        expect(session.response.body).to include("No runs yet")
      end

      it "shows one row per day, with the real-call rate for that day" do
        run = Belay::Run.create!(workflow: "InvoiceWorkflow", workflow_version: "v1",
                                 created_at: Time.zone.local(2026, 1, 1, 10))
        run.steps.create!(position: 0, name: "extract", kind: "llm_call", status: "succeeded",
                          idempotency_key: "#{run.id}:0", cache_hit: false,
                          created_at: Time.zone.local(2026, 1, 1, 10))

        session = get("/belay/stats")

        expect(session.response.status).to eq(200)
        expect(cells(session, "stat-date")).to eq(["2026-01-01"])
        expect(cells(session, "stat-runs")).to eq(["1"])
        expect(cells(session, "stat-calls")).to eq(["1"])
        expect(cells(session, "stat-rate")).to eq(["100.0"])
      end
    end
  end
end
