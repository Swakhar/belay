# frozen_string_literal: true

# Real HTTP-level tests, same philosophy as spec/belay/engine_spec.rb: these
# travel through the dummy host app's actual mount (spec/dummy/config/routes.rb)
# and Belay::Engine's own routes, proving the real controller/view/filtering
# behavior, not a controller-unit shortcut.
#
# Assertions below check for 'class="run-workflow">X<' / 'class="run-status">X<',
# not bare "X" - the workflow/status filter <select>s list every distinct past
# value as an option too (so a human can discover what's filterable), which
# would make a bare substring check pass or fail for the wrong reason: a
# workflow name correctly excluded from the results table is still sitting
# right there in its own <select>'s options.
RSpec.describe "Belay::RunsController#index" do
  after { Belay.reset_config! }

  def get(path)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.get(path)
    session
  end

  def build_run(workflow: "InvoiceWorkflow", status: "pending", **attrs)
    Belay::Run.create!({ workflow: workflow, workflow_version: "v1", status: status }.merge(attrs))
  end

  def row(field, value)
    %(class="run-#{field}">#{value}<)
  end

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
      body = session.response.body
      expect(body).to include(row("workflow", "InvoiceWorkflow")).and include(row("status", "running"))
      expect(body).to include(row("workflow", "RefundWorkflow")).and include(row("status", "completed"))
    end

    it "renders with no runs at all, rather than erroring on an empty table" do
      session = get("/belay/runs")

      expect(session.response.status).to eq(200)
    end

    it "filters to only the given status" do
      build_run(workflow: "InvoiceWorkflow", status: "running")
      build_run(workflow: "InvoiceWorkflow", status: "completed")

      session = get("/belay/runs?status=completed")

      body = session.response.body
      expect(body).to include(row("status", "completed"))
      expect(body).not_to include(row("status", "running"))
    end

    it "ignores an unrecognized status filter instead of raising, since it's untrusted query input" do
      build_run(workflow: "InvoiceWorkflow", status: "running")

      expect { get("/belay/runs?status=not_a_real_status") }.not_to raise_error
    end

    it "filters to only the given workflow" do
      build_run(workflow: "InvoiceWorkflow", status: "running")
      build_run(workflow: "RefundWorkflow", status: "running")

      session = get("/belay/runs?workflow=RefundWorkflow")

      body = session.response.body
      expect(body).to include(row("workflow", "RefundWorkflow"))
      expect(body).not_to include(row("workflow", "InvoiceWorkflow"))
    end

    it "combines status and workflow filters" do
      build_run(workflow: "InvoiceWorkflow", status: "running")
      build_run(workflow: "InvoiceWorkflow", status: "completed")
      build_run(workflow: "RefundWorkflow", status: "running")

      session = get("/belay/runs?workflow=InvoiceWorkflow&status=running")

      body = session.response.body
      expect(body).to include(row("workflow", "InvoiceWorkflow")).and include(row("status", "running"))
      expect(body).not_to include(row("status", "completed"))
      expect(body).not_to include(row("workflow", "RefundWorkflow"))
    end

    it "is also the engine's root route" do
      build_run

      session = get("/belay/")

      expect(session.response.status).to eq(200)
      expect(session.response.body).to include(row("workflow", "InvoiceWorkflow"))
    end
  end
end
