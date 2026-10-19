# frozen_string_literal: true

module Belay
  # Base class for workflow definitions (see README's Target API). Pure declaration: this
  # class only records input names and step definitions in the order they were declared.
  # Nothing here executes a step or validates input at runtime - that's the executor
  # (Phase 1e) and Workflow.start (also Phase 1e), neither of which exist yet.
  class Workflow
    StepDefinition = Struct.new(:name, :options, :block, keyword_init: true)

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

      def step(name, **options, &block)
        raise ArgumentError, "step :#{name} needs a block" unless block

        name = name.to_sym
        raise ArgumentError, "step :#{name} is already declared on #{self}" if raw_steps.any? { |s| s.name == name }

        raw_steps << StepDefinition.new(name: name, options: options.dup.freeze, block: block).freeze
      end

      # Frozen copy, same reasoning as #inputs. Each StepDefinition is frozen too, so a
      # caller can't reach back in and change a step's block or options after the fact.
      def steps
        raw_steps.dup.freeze
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
    end
  end
end
