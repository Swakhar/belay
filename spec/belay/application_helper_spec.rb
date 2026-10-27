# frozen_string_literal: true

RSpec.describe Belay::ApplicationHelper do
  let(:helper_object) { Object.new.extend(described_class).extend(ActionView::Helpers::TagHelper) }

  def badge(status)
    helper_object.status_badge(status)
  end

  it "groups done-and-fine statuses as emerald, regardless of whether they're a run's or a step's" do
    expect(badge("succeeded")).to include("bg-emerald-500/10")
    expect(badge("completed")).to include("bg-emerald-500/10")
  end

  it "groups stopped-and-waiting-on-a-human statuses as amber" do
    expect(badge("paused")).to include("bg-amber-500/10")
    expect(badge("awaiting_approval")).to include("bg-amber-500/10")
    expect(badge("needs_review")).to include("bg-amber-500/10")
  end

  it "groups done-and-not-fine statuses as rose" do
    expect(badge("failed")).to include("bg-rose-500/10")
    expect(badge("cancelled")).to include("bg-rose-500/10")
  end

  it "groups in-progress statuses as sky" do
    expect(badge("running")).to include("bg-sky-500/10")
    expect(badge("started")).to include("bg-sky-500/10")
  end

  it "falls back to a neutral slate for anything else, rather than raising on an unrecognized status" do
    expect(badge("pending")).to include("bg-slate-500/10")
    expect(badge("skipped")).to include("bg-slate-500/10")
    expect(badge("something_unexpected")).to include("bg-slate-500/10")
  end

  it "renders the status text itself, visibly, not just a color" do
    expect(badge("succeeded")).to include(">succeeded<")
  end
end
