# frozen_string_literal: true

require_relative "lib/belay/version"

Gem::Specification.new do |spec|
  spec.name = "belay"
  spec.version = Belay::VERSION
  spec.authors = ["Swakhar Dey"]
  spec.email = ["swakhar.me@gmail.com"]

  spec.summary = "Durable execution for AI agents in Rails."
  spec.description = "Belay records every model and tool call as a Postgres row, so an AI workflow " \
                     "that crashes partway resumes from its last checkpoint instead of starting over."
  spec.homepage = "https://github.com/Swakhar/belay"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "app/**/*", "config/routes.rb", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "actionpack", ">= 7.1", "< 9"
  spec.add_dependency "activejob", ">= 7.1", "< 9"
  spec.add_dependency "activerecord", ">= 7.1", "< 9"
  # Validates ctx.llm's response against schema: - see lib/belay/context.rb for why
  # this is the one new dependency the gem takes on: a correct JSON Schema validator
  # is worth depending on rather than hand-rolling (unlike AnthropicProvider's own
  # HTTP layer, this is a real spec with real edge cases to get wrong). Pure Ruby,
  # no ActiveSupport/Rails coupling of its own.
  spec.add_dependency "json_schemer", "~> 2.5"
  spec.add_dependency "pg", "~> 1.1"
  spec.add_dependency "railties", ">= 7.1", "< 9"
end
