# frozen_string_literal: true

# Real HTTP-level tests, same philosophy as spec/belay/engine_spec.rb: these
# travel through the dummy host app's actual mount (spec/dummy/config/routes.rb)
# and Belay::Engine's own routes, proving the real controller/view/filtering
# behavior, not a controller-unit shortcut.
#
# Assertions below parse the response with Nokogiri and read .run-workflow/
# .run-status cells by CSS class, not by searching the raw body for a bare
# workflow/status string - the workflow/status filter <select>s list every
# distinct past value as an option too (so a human can discover what's
# filterable), which would make a bare substring check pass or fail for the
# wrong reason: a workflow name correctly excluded from the results table is
# still sitting right there in its own <select>'s options. Parsing properly
# instead of string-matching also means this doesn't care about incidental
# markup details like HTML attribute order.
RSpec.describe Belay::RunsController do
  after { Belay.reset_config! }

  def get(path)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.get(path)
    session
  end

  def build_run(workflow: "InvoiceWorkflow", status: "pending", **attrs)
    Belay::Run.create!({ workflow: workflow, workflow_version: "v1", status: status }.merge(attrs))
  end

  def build_step(run, **attrs)
    defaults = { name: "extract", position: 0, attempt: 1, status: "succeeded", kind: "decision" }
    attrs = defaults.merge(attrs)
    run.steps.create!(attrs.merge(idempotency_key: "#{run.id}:#{attrs[:position]}"))
  end

  def cells(session, css_class)
    Nokogiri::HTML(session.response.body).css(".#{css_class}").map(&:text)
  end

  describe "#index" do
    it "requires authentication, same as every other engine route - nothing here bypasses the gate" do
      expect { get("/belay/runs") }.to raise_error(Belay::Error, /authenticate_with/)
    end

    context "once authenticated" do
      before { Belay.configure { |c| c.authenticate_with = ->(_request) { true } } }

      it "lists every run, showing its workflow and status" do
        build_run(workflow: "InvoiceWorkflow", status: "running")
        build_run(workflow: "RefundWorkflow", status: "completed")

        session = get("/belay/runs")

        expect(session.response.status).to eq(200)
        expect(cells(session, "run-workflow")).to contain_exactly("InvoiceWorkflow", "RefundWorkflow")
        expect(cells(session, "run-status")).to contain_exactly("running", "completed")
      end

      it "renders with no runs at all, rather than erroring on an empty table" do
        session = get("/belay/runs")

        expect(session.response.status).to eq(200)
      end

      it "filters to only the given status" do
        build_run(workflow: "InvoiceWorkflow", status: "running")
        build_run(workflow: "InvoiceWorkflow", status: "completed")

        session = get("/belay/runs?status=completed")

        expect(cells(session, "run-status")).to eq(["completed"])
      end

      it "ignores an unrecognized status filter instead of raising, since it's untrusted query input" do
        build_run(workflow: "InvoiceWorkflow", status: "running")

        expect { get("/belay/runs?status=not_a_real_status") }.not_to raise_error
      end

      it "filters to only the given workflow" do
        build_run(workflow: "InvoiceWorkflow", status: "running")
        build_run(workflow: "RefundWorkflow", status: "running")

        session = get("/belay/runs?workflow=RefundWorkflow")

        expect(cells(session, "run-workflow")).to eq(["RefundWorkflow"])
      end

      it "combines status and workflow filters" do
        build_run(workflow: "InvoiceWorkflow", status: "running")
        build_run(workflow: "InvoiceWorkflow", status: "completed")
        build_run(workflow: "RefundWorkflow", status: "running")

        session = get("/belay/runs?workflow=InvoiceWorkflow&status=running")

        expect(cells(session, "run-workflow")).to eq(["InvoiceWorkflow"])
        expect(cells(session, "run-status")).to eq(["running"])
      end

      it "is also the engine's root route" do
        build_run

        session = get("/belay/")

        expect(session.response.status).to eq(200)
        expect(cells(session, "run-workflow")).to eq(["InvoiceWorkflow"])
      end

      it "links each run to its own show page" do
        run = build_run

        session = get("/belay/runs")

        expect(session.response.body).to include("/belay/runs/#{run.id}")
      end
    end
  end

  describe "#show" do
    it "requires authentication, same as every other engine route" do
      run = build_run

      expect { get("/belay/runs/#{run.id}") }.to raise_error(Belay::Error, /authenticate_with/)
    end

    context "once authenticated" do
      before { Belay.configure { |c| c.authenticate_with = ->(_request) { true } } }

      it "shows the run's workflow, status and workflow_version" do
        run = build_run(workflow: "InvoiceWorkflow", status: "running")

        session = get("/belay/runs/#{run.id}")

        expect(session.response.status).to eq(200)
        body = session.response.body
        expect(body).to include("InvoiceWorkflow").and include("running").and include("v1")
      end

      it "returns a plain 404 for a run id that doesn't exist, rather than a raw unhandled error" do
        session = get("/belay/runs/#{SecureRandom.uuid}")

        expect(session.response.status).to eq(404)
      end

      it "shows every step in the timeline, in position order" do
        run = build_run
        build_step(run, name: "extract", position: 0, status: "succeeded")
        build_step(run, name: "book", position: 1, status: "succeeded")

        session = get("/belay/runs/#{run.id}")

        body = session.response.body
        expect(body.index("extract")).to be < body.index("book")
      end

      it "shows every attempt of a retried step, not just the latest" do
        run = build_run
        build_step(run, name: "flaky", position: 0, attempt: 1, status: "failed")
        build_step(run, name: "flaky", position: 0, attempt: 2, status: "succeeded")

        session = get("/belay/runs/#{run.id}")

        body = session.response.body
        expect(body.scan(">flaky<").count).to eq(2)
      end

      it "shows the prompt, response, tokens and cost for an llm_call step" do
        run = build_run
        build_step(run, name: "ask", status: "succeeded", kind: "llm_call", input: "extract the total",
                        output: { "total_cents" => 4200 }, provider: "Belay::AnthropicProvider",
                        model: "claude-sonnet-5-5", input_tokens: 10, output_tokens: 5, cost_cents: 18)

        session = get("/belay/runs/#{run.id}")

        body = session.response.body
        expect(body).to include("extract the total") # prompt
        expect(body).to include("4200") # response
        expect(body).to include("claude-sonnet-5-5")
        expect(body).to include("10").and include("5") # tokens
        expect(body).to include("0.18") # cost_cents formatted as dollars
      end

      it "shows a step's error when it failed with a {class, message} error" do
        run = build_run
        build_step(run, name: "ask", status: "failed", error: { "class" => "RuntimeError", "message" => "boom" })

        session = get("/belay/runs/#{run.id}")

        expect(session.response.body).to include("boom")
      end

      it "shows a step's error when it's a {reason} error, not just {class, message} - " \
         "needs_review and a rejected gate both write this shape" do
        run = build_run
        build_step(run, name: "approval", status: "needs_review", error: { "reason" => "not idempotent" })

        session = get("/belay/runs/#{run.id}")

        expect(session.response.body).to include("not idempotent")
      end
    end
  end
end
