I am building a Ruby gem called `belay`: a durable execution runtime for AI agents in Rails. Steps persist to Postgres via ActiveRecord so runs resume after crashes, pause for human approval, and can be replayed against new models. Target Ruby 3.2+, Rails 7.1+, Postgres only. Module is `Belay`, workflows subclass `Belay::Workflow`, tables are prefixed `belay_`.

Rules for this project:
- Ruby idioms over Python-style ports. Feels like Rails, not LangChain.
- Every feature starts with a failing test. RSpec.
- No network in tests — use FakeProvider.
- Public API changes must be reflected in the README in the same change.
- Every implementation step is one commit, following COMMITS.md. Give me the exact commit message with each change, and don't bundle two plan items into one commit.
- Challenge my design decisions when they are wrong. Do not agree by default.
- Current phase is at the top of STATUS.md. Do not jump ahead.
