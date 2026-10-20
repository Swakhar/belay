#!/usr/bin/env ruby
# frozen_string_literal: true

# Child process for spec/property_spec.rb. Boots the dummy Rails app directly - NOT
# spec/spec_helper.rb, which would re-run Belay::TestSchema.sync! and drop+recreate
# the test database, destroying the very Run row the parent process just committed.
# CRASH_AT_POSITION, if set in this process's environment, is read by the matching
# step inside property_test_workflow.rb itself - nothing here swaps steps at
# runtime. Same shape as crash_test_runner.rb, kept as its own file rather than
# shared, since the two require different workflow definition files.
require_relative "../dummy/config/environment"
require "belay"
require_relative "property_test_workflow"

run = Belay::Run.find(ARGV[0])
Belay::Executor.new(run).call
