# frozen_string_literal: true

require "digest"

module Belay
  # Base class for workflow definitions (see README's Target API). Pure declaration: this
  # class only records input names and step definitions in the order they were declared.
  # Nothing here executes a step or validates input at runtime - that's the executor
  # (Phase 1e) and Workflow.start (also Phase 1e), neither of which exist yet.
  class Workflow
    StepDefinition = Struct.new(:name, :kind, :options, :block, keyword_init: true)

    class << self
      def input(*names)
        names.each do |name|
          name = name.to_sym
          raise ArgumentError, "input :#{name} is already declared on #{self}" if raw_inputs.include?(name)

          raw_inputs << name
        end
      end

      # Returns a frozen copy: mutating the result (push, clear, reassign) can never
      # corrupt what .input actually declared, and can't bypass its duplicate check.
      def inputs
        raw_inputs.dup.freeze
      end

      # kind isn't validated against Belay::Step's kind enum here - that's the AR/
      # persistence layer's job (Step#kind), not this thin declaration layer's. nil
      # (the default, since no Target API example passes it) hashes consistently with
      # itself in workflow_version; inferring a real kind is executor work (Phase 1e+).
      #
      # kind: is reserved by this gem the same way the belay_steps.kind column is - a
      # host app passing an unrelated option literally named kind: would have it
      # silently captured here instead of landing in options. Accepted, not guarded:
      # the name is already Belay-specific throughout this project, not a generic term
      # a workflow author would likely reach for on their own.
      def step(name, kind: nil, **options, &block)
        raise ArgumentError, "step :#{name} needs a block" unless block

        validate_step_kind!(name, kind)

        name = name.to_sym
        raise ArgumentError, "step :#{name} is already declared on #{self}" if raw_steps.any? { |s| s.name == name }

        raw_steps << StepDefinition.new(
          name: name, kind: kind&.to_sym, options: options.dup.freeze, block: block
        ).freeze
      end

      # Frozen copy, same reasoning as #inputs. Each StepDefinition is frozen too, so a
      # caller can't reach back in and change a step's block or options after the fact.
      def steps
        raw_steps.dup.freeze
      end

      # Hashes structure, not block bodies: Ruby source can't be hashed reliably (a
      # renamed local variable or a reformatted block changes nothing about what the
      # step actually does, but would change its source text). Covers declared inputs,
      # and each step's name and kind in order - deliberately not step options yet
      # (idempotent:/retries: aren't interpreted anywhere yet either; see .step's
      # comment). No explicit position field: Array#inspect is already order-sensitive
      # on its own, so swapping two steps changes the fingerprint without needing one.
      def workflow_version
        fingerprint = [inputs, steps.map { |step| [step.name, step.kind] }]
        Digest::SHA256.hexdigest(fingerprint.inspect)
      end

      private

      # Subclasses never inherit a superclass's declarations: @inputs/@steps are plain
      # class-level ivars, not class_attribute. `class Child < Base; end` with no further
      # declarations has Child.steps == [], even if Base declared steps - nothing here
      # makes that loud, so don't build a "shared base workflow" on this assumption.
      def raw_inputs
        @raw_inputs ||= []
      end

      def raw_steps
        @raw_steps ||= []
      end

      def validate_step_kind!(name, kind)
        return if kind.nil? || kind.is_a?(String) || kind.is_a?(Symbol)

        raise ArgumentError, "step :#{name} kind: must be a String, Symbol, or nil, got #{kind.inspect}"
      end
    end
  end
end
