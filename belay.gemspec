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

  spec.files = Dir["lib/**/*", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activejob", ">= 7.1", "< 9"
  spec.add_dependency "activerecord", ">= 7.1", "< 9"
  spec.add_dependency "railties", ">= 7.1", "< 9"
end
