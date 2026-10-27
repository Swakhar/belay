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

  def post(path, params)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.post(path, params: params)
    session
  end

  def redirect_path(session)
    URI(session.response.headers["Location"]).path
  end

  def build_paused_run
    stub_const("RunsControllerSpecGateWorkflow", Class.new(Belay::Workflow) do
      input :invoice_id
      step(:extract) { |ctx| { total_cents: ctx.invoice_id * 100 } }
      gate(:approval, when: ->(_ctx) { true })
      step(:book) { |ctx| { booked_total_cents: ctx.approval&.dig(:total_cents) } }
    end)
    run = Belay::Run.create!(workflow: "RunsControllerSpecGateWorkflow",
                             workflow_version: RunsControllerSpecGateWorkflow.workflow_version,
                             input: { invoice_id: 42 })
    Belay::Executor.new(run).call
    run.reload
  end

  def simulate_crashed_step(run)
    run.steps.create!(position: 0, name: "extract", kind: "decision", status: "started",
                      idempotency_key: "#{run.id}:0")
  end

  def build_run_with_needs_review # rubocop:disable Metrics/AbcSize
    stub_const("RunsControllerSpecNeedsReviewWorkflow", Class.new(Belay::Workflow) do
      input :invoice_id
      step(:extract) { |ctx| { total_cents: ctx.invoice_id * 100 } } # no idempotent: true
      step(:book) { |ctx| { booked_total_cents: ctx.extract&.dig(:total_cents) } }
    end)
    run = Belay::Run.create!(workflow: "RunsControllerSpecNeedsReviewWorkflow",
                             workflow_version: RunsControllerSpecNeedsReviewWorkflow.workflow_version,
                             input: { invoice_id: 42 })
    simulate_crashed_step(run) # a non-idempotent step left "started" - simulates a crash mid-step
    expect { Belay::Executor.new(run).call }.to raise_error(Belay::Error)
    run.reload
  end

  def build_run(workflow: "InvoiceWorkflow", status: "pending", **attrs)
    Belay::Run.create!({ workflow: workflow, workflow_version: "v1", status: status }.merge(attrs))
  end

  # Distinct created_at (not just distinct workflow names) is what actually
  # gives each run a deterministic position in the index's created_at: :desc
  # order - without it, 30 runs created in the same test could tie on
  # creation timestamp depending on DB timestamp precision, making which ones
  # land on page 1 vs page 2 nondeterministic.
  def build_runs_with_distinct_order(count)
    base = Time.current
    count.times { |i| build_run(workflow: "Workflow#{i}", created_at: base + i.seconds) }
  end

  def configure_fake_provider(*responses)
    Belay.configure { |c| c.provider = Belay::FakeProvider.new(responses: responses) }
  end

  def build_replayable_run
    stub_const("RunsControllerSpecReplayWorkflow", Class.new(Belay::Workflow) do
      input :invoice_id
      step(:extract) { |ctx| ctx.llm(model: "x", prompt: "y") }
      step(:verify) { |_ctx| { checked: true } }
    end)
    Belay::Run.create!(workflow: "RunsControllerSpecReplayWorkflow",
                       workflow_version: RunsControllerSpecReplayWorkflow.workflow_version,
                       input: { invoice_id: 1 }).tap { |run| Belay::Executor.new(run).call }
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

      it "renders an empty state with no runs at all, rather than erroring on an empty table" do
        session = get("/belay/runs")

        expect(session.response.status).to eq(200)
        expect(session.response.body).to include("No runs yet")
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

      it "hands its own current path, filters included, to each run link as return_to: - " \
         "so the run's own back link can restore the exact filtered list, not just the bare index" do
        run = build_run(workflow: "InvoiceWorkflow", status: "running")

        session = get("/belay/runs?status=running")

        doc = Nokogiri::HTML(session.response.body)
        href = doc.css(".run-workflow").first["href"]
        expect(href).to eq("/belay/runs/#{run.id}?return_to=%2Fbelay%2Fruns%3Fstatus%3Drunning")
      end

      it "limits the runs list to 25 per page, rather than rendering every run at once" do
        build_runs_with_distinct_order(30)

        session = get("/belay/runs")

        expect(cells(session, "run-workflow").size).to eq(25)
      end

      it "shows the remaining runs on page 2 - not whatever page 1 already showed" do
        build_runs_with_distinct_order(30)

        page1 = cells(get("/belay/runs"), "run-workflow")
        page2 = cells(get("/belay/runs?page=2"), "run-workflow")

        expect(page2.size).to eq(5)
        expect(page1 & page2).to be_empty
      end

      it "shows no pagination controls at all when every run already fits on one page" do
        build_run

        session = get("/belay/runs")

        expect(Nokogiri::HTML(session.response.body).css(".pagination-status")).to be_empty
      end

      it "shows Page X of Y once there's more than one page" do
        build_runs_with_distinct_order(30)

        session = get("/belay/runs?page=2")

        text = Nokogiri::HTML(session.response.body).css(".pagination-status").first.text
        expect(text).to eq("Page 2 of 2")
      end

      it "disables Previous on the first page and Next on the last page, rather than linking nowhere useful" do
        build_runs_with_distinct_order(30)

        page1 = Nokogiri::HTML(get("/belay/runs").response.body)
        expect(page1.css(".pagination-prev")).to be_empty
        expect(page1.css(".pagination-next")).not_to be_empty

        page2 = Nokogiri::HTML(get("/belay/runs?page=2").response.body)
        expect(page2.css(".pagination-prev")).not_to be_empty
        expect(page2.css(".pagination-next")).to be_empty
      end

      it "keeps the current status filter in the pagination links, not just the table rows" do
        base = Time.current
        30.times { |i| build_run(workflow: "InvoiceWorkflow", status: "running", created_at: base + i.seconds) }

        session = get("/belay/runs?status=running")

        href = Nokogiri::HTML(session.response.body).css(".pagination-next").first["href"]
        expect(href).to include("status=running").and include("page=2")
      end

      it "clamps a ?page= past the last real page to the last page, rather than showing an empty table" do
        build_runs_with_distinct_order(30)

        session = get("/belay/runs?page=999")

        doc = Nokogiri::HTML(session.response.body)
        expect(doc.css(".pagination-status").first.text).to eq("Page 2 of 2")
        expect(cells(session, "run-workflow").size).to eq(5)
      end

      it "clamps a non-numeric or negative ?page= to the first page, rather than raising" do
        build_runs_with_distinct_order(30)

        expect { get("/belay/runs?page=not-a-number") }.not_to raise_error
        expect { get("/belay/runs?page=-5") }.not_to raise_error

        doc = Nokogiri::HTML(get("/belay/runs?page=-5").response.body)
        expect(doc.css(".pagination-status").first.text).to eq("Page 1 of 2")
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

      # Regression tripwire for show.html.erb's needs_review-hiding condition
      # (added for replay shadows) - confirms the "&& !@run.replay_of" half
      # never accidentally hides this for an ORDINARY run, which has no
      # replay_of at all. This is the dashboard's only way to resolve a real
      # needs_review step, so losing it silently would be a real regression.
      it "shows the needs_review resolve section for an ordinary run (no replay_of) with a real pending_needs_review" do
        run = build_run_with_needs_review

        session = get("/belay/runs/#{run.id}")

        expect(session.response.body).to include("Needs review")
      end

      it "links back to the plain runs index when there's no return_to: (visited directly, not via the index)" do
        run = build_run

        session = get("/belay/runs/#{run.id}")

        doc = Nokogiri::HTML(session.response.body)
        expect(doc.css(".back-to-runs").first["href"]).to eq("/belay/runs")
      end

      it "links back to the exact filtered list given in return_to:" do
        run = build_run

        session = get("/belay/runs/#{run.id}?return_to=%2Fbelay%2Fruns%3Fstatus%3Drunning")

        doc = Nokogiri::HTML(session.response.body)
        expect(doc.css(".back-to-runs").first["href"]).to eq("/belay/runs?status=running")
      end

      it "falls back to the plain runs index for a return_to: pointing off-site, rather than letting a " \
         "hand-edited URL turn the back link into an open redirect" do
        run = build_run

        session = get("/belay/runs/#{run.id}?return_to=https%3A%2F%2Fevil.example%2Fphish")

        doc = Nokogiri::HTML(session.response.body)
        expect(doc.css(".back-to-runs").first["href"]).to eq("/belay/runs")
      end
    end
  end

  describe "#approve" do
    it "requires authentication" do
      run = build_paused_run

      expect { post("/belay/runs/#{run.id}/approve", by: "alice") }.to raise_error(Belay::Error, /authenticate_with/)
    end

    context "once authenticated" do
      before { Belay.configure { |c| c.authenticate_with = ->(_request) { true } } }

      it "approves the pending gate and redirects back to the run" do
        run = build_paused_run

        session = post("/belay/runs/#{run.id}/approve", by: "alice@example.com")

        expect(session.response.status).to eq(302)
        expect(redirect_path(session)).to eq("/belay/runs/#{run.id}")
        expect(run.reload.pending_gate).to be_nil
        expect(run.approvals.sole.decided_by).to eq("alice@example.com")
      end

      it "accepts an edited payload as JSON, which becomes the gate's own output" do
        run = build_paused_run

        post("/belay/runs/#{run.id}/approve", by: "alice", edited_payload: '{"total_cents": 999}')

        gate = run.steps.find_by(name: "approval")
        expect(gate.output).to eq("total_cents" => 999)
      end

      it "redirects back with nothing approved, rather than crashing, when edited_payload isn't valid JSON" do
        run = build_paused_run

        session = post("/belay/runs/#{run.id}/approve", by: "alice", edited_payload: "{not valid json")

        expect(session.response.status).to eq(302)
        expect(run.reload.pending_gate).not_to be_nil
      end

      it "redirects back with nothing approved, rather than raising, when the run has no pending gate" do
        run = build_run

        session = post("/belay/runs/#{run.id}/approve", by: "alice")

        expect(session.response.status).to eq(302)
        expect(redirect_path(session)).to eq("/belay/runs/#{run.id}")
      end

      it "requires by: to be present - an approval with no recorded actor defeats the point of the audit trail" do
        run = build_paused_run

        session = post("/belay/runs/#{run.id}/approve", by: "")

        expect(session.response.status).to eq(302)
        session.follow_redirect!
        expect(session.response.body).to include("who is approving this?")
        expect(run.reload.pending_gate).not_to be_nil
        expect(run.approvals.count).to eq(0)
      end
    end
  end

  describe "#reject" do
    it "requires authentication" do
      run = build_paused_run

      expect { post("/belay/runs/#{run.id}/reject", by: "alice") }.to raise_error(Belay::Error, /authenticate_with/)
    end

    context "once authenticated" do
      before { Belay.configure { |c| c.authenticate_with = ->(_request) { true } } }

      it "rejects the pending gate, fails the run, and redirects back to it" do
        run = build_paused_run

        session = post("/belay/runs/#{run.id}/reject", by: "alice@example.com")

        expect(session.response.status).to eq(302)
        expect(redirect_path(session)).to eq("/belay/runs/#{run.id}")
        expect(run.reload.status).to eq("failed")
        expect(run.approvals.sole.decided_by).to eq("alice@example.com")
      end

      it "redirects back with nothing rejected, rather than raising, when the run has no pending gate" do
        run = build_run

        session = post("/belay/runs/#{run.id}/reject", by: "alice")

        expect(session.response.status).to eq(302)
      end

      it "requires by: to be present" do
        run = build_paused_run

        session = post("/belay/runs/#{run.id}/reject", by: "")

        expect(session.response.status).to eq(302)
        session.follow_redirect!
        expect(session.response.body).to include("who is rejecting this?")
        expect(run.reload.status).to eq("paused")
        expect(run.approvals.count).to eq(0)
      end
    end
  end

  describe "#resolve" do
    it "requires authentication" do
      run = build_run_with_needs_review

      expect { post("/belay/runs/#{run.id}/resolve", by: "alice", outcome: "succeeded") }
        .to raise_error(Belay::Error, /authenticate_with/)
    end

    context "once authenticated" do
      before { Belay.configure { |c| c.authenticate_with = ->(_request) { true } } }

      it "resolves the step succeeded with the given output, resumes the run and redirects back to it" do
        run = build_run_with_needs_review

        session = post("/belay/runs/#{run.id}/resolve", by: "alice@example.com", outcome: "succeeded",
                                                        output: '{"total_cents": 4200}')

        expect(session.response.status).to eq(302)
        expect(redirect_path(session)).to eq("/belay/runs/#{run.id}")
        step = run.steps.find_by(name: "extract")
        expect(step.status).to eq("succeeded")
        expect(step.output).to eq("total_cents" => 4200)
        expect(step.resolved_by).to eq("alice@example.com")
      end

      it "resolves the step failed and fails the run outright" do
        run = build_run_with_needs_review

        session = post("/belay/runs/#{run.id}/resolve", by: "alice", outcome: "failed")

        expect(session.response.status).to eq(302)
        expect(run.reload.status).to eq("failed")
        expect(run.steps.find_by(name: "extract").resolved_by).to eq("alice")
      end

      it "redirects back with nothing resolved, rather than crashing, when output isn't valid JSON" do
        run = build_run_with_needs_review

        session = post("/belay/runs/#{run.id}/resolve", by: "alice", outcome: "succeeded", output: "{not json")

        expect(session.response.status).to eq(302)
        expect(run.reload.pending_needs_review).not_to be_nil
      end

      it "ignores a malformed output: when resolving failed - it's never used, so it shouldn't block the request" do
        run = build_run_with_needs_review

        session = post("/belay/runs/#{run.id}/resolve", by: "alice", outcome: "failed", output: "{not json")

        expect(session.response.status).to eq(302)
        expect(run.reload.status).to eq("failed")
      end

      it "redirects back with nothing resolved for an unrecognized outcome, rather than raising" do
        run = build_run_with_needs_review

        session = post("/belay/runs/#{run.id}/resolve", by: "alice", outcome: "maybe")

        expect(session.response.status).to eq(302)
        session.follow_redirect!
        expect(session.response.body).to include("outcome must be succeeded or failed")
        expect(run.reload.pending_needs_review).not_to be_nil
      end

      it "redirects back with nothing resolved, rather than raising, when the run has no needs_review step" do
        run = build_run

        session = post("/belay/runs/#{run.id}/resolve", by: "alice", outcome: "succeeded")

        expect(session.response.status).to eq(302)
      end

      it "requires by: to be present" do
        run = build_run_with_needs_review

        session = post("/belay/runs/#{run.id}/resolve", by: "", outcome: "succeeded")

        expect(session.response.status).to eq(302)
        session.follow_redirect!
        expect(session.response.body).to include("who is resolving this?")
        expect(run.reload.pending_needs_review).not_to be_nil
      end
    end
  end

  describe "#show for a replay shadow run" do
    before { Belay.configure { |c| c.authenticate_with = ->(_request) { true } } }
    after { Belay.reset_config! }

    it "links back to the original it was replayed from" do
      configure_fake_provider({ "total_cents" => 1 }, { "total_cents" => 2 })
      original = build_replayable_run
      shadow = original.replay(model: "claude-opus-5-5")

      session = get("/belay/runs/#{shadow.id}")

      expect(session.response.body).to include("Replayed from").and include(original.id)
    end

    it "lists its replays, each linking to its own diff view" do
      configure_fake_provider({ "total_cents" => 1 }, { "total_cents" => 2 })
      original = build_replayable_run
      shadow = original.replay(model: "claude-opus-5-5")

      session = get("/belay/runs/#{original.id}")

      expect(session.response.body).to include("Replays").and include(shadow.id)
    end

    it "does not render needs_review resolve, even for a replay shadow with a genuine pending_needs_review row" do
      configure_fake_provider({ "total_cents" => 1 })
      stub_const("RunsControllerSpecReplayFailWorkflow", Class.new(Belay::Workflow) do
        input :invoice_id
        step(:extract) { |ctx| ctx.llm(model: "x", prompt: "y") }
        step(:book) { |_ctx| raise "boom" }
      end)
      run = Belay::Run.create!(workflow: "RunsControllerSpecReplayFailWorkflow",
                               workflow_version: RunsControllerSpecReplayFailWorkflow.workflow_version,
                               input: { invoice_id: 1 })
      expect { Belay::Executor.new(run).call }.to raise_error("boom")
      configure_fake_provider({ "total_cents" => 1 })
      shadow = begin
        run.replay(model: "claude-opus-5-5")
      rescue Belay::Error
        Belay::Run.where(replay_of_id: run.id).sole
      end
      expect(shadow.pending_needs_review).not_to be_nil # sanity - this is the exact scenario being guarded against

      session = get("/belay/runs/#{shadow.id}")

      expect(session.response.body).not_to include("Needs review")
    end
  end

  describe "#diff" do
    it "requires authentication" do
      run = build_run

      expect { get("/belay/runs/#{run.id}/diff") }.to raise_error(Belay::Error, /authenticate_with/)
    end

    context "once authenticated" do
      before { Belay.configure { |c| c.authenticate_with = ->(_request) { true } } }
      after { Belay.reset_config! }

      it "shows each step's original and replay output side by side" do
        configure_fake_provider({ "total_cents" => 4200 }, { "total_cents" => 9999 })
        original = build_replayable_run
        shadow = original.replay(model: "claude-opus-5-5")

        session = get("/belay/runs/#{shadow.id}/diff")

        expect(session.response.status).to eq(200)
        doc = Nokogiri::HTML(session.response.body)
        statuses = doc.css(".diff-status").map(&:text).map(&:strip)
        expect(statuses).to include("changed").and include("unchanged")
      end

      # The one UI branch in diff.html.erb (diff_entry's replayed: false,
      # found by review on the prior commit) that the test above never
      # exercises - reproduced here the real way: a replay whose provider
      # runs out of scripted responses partway through, so a later llm_call
      # step is never dispatched at all, exactly as it would be for a real
      # model/provider error partway through a replay.
      it "shows 'not reached' for a step the shadow's own replay never got to" do
        configure_fake_provider({ "total_cents" => 1 }, { "total_cents" => 2 }, { "total_cents" => 3 })
        stub_const("RunsControllerSpecReplayHaltWorkflow", Class.new(Belay::Workflow) do
          input :invoice_id
          step(:first) { |ctx| ctx.llm(model: "x", prompt: "a") }
          step(:second) { |ctx| ctx.llm(model: "x", prompt: "b") }
          step(:third) { |ctx| ctx.llm(model: "x", prompt: "c") }
        end)
        original = Belay::Run.create!(workflow: "RunsControllerSpecReplayHaltWorkflow",
                                      workflow_version: RunsControllerSpecReplayHaltWorkflow.workflow_version,
                                      input: { invoice_id: 1 })
        Belay::Executor.new(original).call
        configure_fake_provider({ "total_cents" => 9 }) # only enough for :first - :second then halts replay
        shadow = begin
          original.replay(model: "claude-opus-5-5")
        rescue Belay::FakeProvider::ScriptExhaustedError
          Belay::Run.where(replay_of_id: original.id).sole
        end

        session = get("/belay/runs/#{shadow.id}/diff")

        doc = Nokogiri::HTML(session.response.body)
        statuses = doc.css(".diff-status").map(&:text).map(&:strip)
        expect(statuses).to include("not reached")
      end

      it "redirects back with a flash alert, rather than a raw 500, for a run that isn't a replay" do
        run = build_run

        session = get("/belay/runs/#{run.id}/diff")

        expect(session.response.status).to eq(302)
        session.follow_redirect!
        expect(session.response.body).to include("is not a replay")
      end
    end
  end
end
