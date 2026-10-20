#!/usr/bin/env ruby
# frozen_string_literal: true

# Child process for spec/crash_spec.rb. Boots the dummy Rails app directly - NOT
# spec/spec_helper.rb, which would re-run Belay::TestSchema.sync! and drop+recreate
# the test database, destroying the very Run row the parent process just committed.
# CRASH_AT_POSITION, if set in this process's environment, is read by the matching
# step inside crash_test_workflow.rb itself - nothing here swaps steps at runtime.
require_relative "../dummy/config/environment"
require "belay"
require_relative "crash_test_workflow"

run = Belay::Run.find(ARGV[0])
Belay::Executor.new(run).call
