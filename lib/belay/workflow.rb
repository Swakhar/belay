# frozen_string_literal: true

require "digest"

module Belay
  # Base class for workflow definitions (see README's Target API). .input/.step are pure
  # declaration; .start (below) is where a Run actually gets created and executed.
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
        name = reserve_name!(name)

        raw_steps << StepDefinition.new(
          name: name, kind: kind&.to_sym, options: options.dup.freeze, block: block
        ).freeze
      end

      # DESIGN_DECISIONS #7: "Gates are steps" - a gate lives in the same ordered
      # raw_steps list as step (so Executor's single each_with_index walk sees it in
      # position, and workflow_version's fingerprint already covers it via
      # steps.map { [name, kind] }, with no special-casing needed there). kind: is
      # always :gate here, not an option the caller can override - unlike step,
      # where kind: is optional metadata, a gate's kind is what makes it one.
      #
      # when: is accepted through **options rather than declared as its own `when:`
      # keyword parameter. Ruby accepts when: as a keyword argument NAME just fine
      # (def gate(name, when:) parses), but referencing it afterward as a bare local
      # variable does not - `when` alone is reserved for case/when, a SyntaxError
      # distinct from the argument's own definition. Reading it back out of options
      # (options[:when]) sidesteps that entirely rather than requiring
      # binding.local_variable_get(:when) everywhere it's used.
      #
      # No block: a gate has nothing to execute - when: decides skip (false) or wait
      # for a human (true). What the executor actually does with kind: :gate is the
      # next commit's job; this one only declares it.
      def gate(name, **options)
        raise ArgumentError, "gate :#{name} must not pass kind: - a gate's kind is always :gate" if options.key?(:kind)

        condition = options[:when]
        validate_gate_when!(name, condition)
        name = reserve_name!(name)

        raw_steps << StepDefinition.new(
          name: name, kind: :gate, options: options.dup.freeze, block: nil
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

      # README's Target API: InvoiceWorkflow.start(invoice_id: 42, idempotency_key: "inv-42").
      # idempotency_key: dedups at the RUN level (distinct from a step's own
      # step_idempotency_key): calling .start twice with the same key returns the same
      # Run rather than starting a second one, racing on belay_runs' own unique index
      # on idempotency_key rather than a check-then-create in Ruby, which two
      # concurrent callers could both pass.
      #
      # The dedup lookup runs before input validation, not after: a repeat call with
      # the same key is asking "what happened to that run," and the input was already
      # validated when the run was first created - a caller-side bug on a retry
      # (stale/missing input) shouldn't turn a successful repeat lookup into an
      # ArgumentError for a run that already exists and needs no further input at all.
      #
      # Only the run THIS call actually creates gets executed. A found-existing run -
      # whether found outright or found after losing the create race - is returned
      # without calling the executor on it: this gem has no lease mechanism yet
      # (Phase 1f) to make running the same Executor concurrently from two places
      # safe, so piling onto a run some OTHER caller may already be executing isn't
      # attempted here.
      def start(idempotency_key:, **input)
        existing = Run.find_by(idempotency_key: idempotency_key)
        return check_same_workflow!(existing) if existing

        validate_input!(input)
        run, newly_created = find_or_create_run(idempotency_key, input)
        Executor.new(run).call if newly_created
        run
      end

      private

      def validate_input!(input)
        missing = inputs - input.keys
        raise ArgumentError, "#{self}.start is missing required input(s): #{missing.inspect}" unless missing.empty?

        extra = input.keys - inputs
        return if extra.empty?

        raise ArgumentError,
              "#{self}.start received undeclared input(s): #{extra.inspect} - declared inputs are #{inputs.inspect}"
      end

      # The first find_by in #start above already covers the common case; this
      # second lookup only runs for the race window between that read and this
      # create - rescue is scoped to just create_run, not the surrounding lookup,
      # so a RecordNotUnique from somewhere unexpected is never silently caught here.
      def find_or_create_run(idempotency_key, input)
        [create_run(idempotency_key, input), true]
      rescue ActiveRecord::RecordNotUnique
        [check_same_workflow!(Run.find_by!(idempotency_key: idempotency_key)), false]
      end

      def create_run(idempotency_key, input)
        raise Error, "#{self} must be assigned to a constant before .start can use it as a workflow name" if name.nil?

        Run.create!(workflow: name, workflow_version: workflow_version, input: input,
                    idempotency_key: idempotency_key)
      end

      # A reused idempotency_key string across two different Workflow subclasses would
      # otherwise silently return a Run belonging to the wrong workflow entirely.
      def check_same_workflow!(run)
        return run if run.workflow == name

        raise Error, "idempotency_key #{run.idempotency_key.inspect} already belongs to a #{run.workflow} run " \
                     "(belay_runs##{run.id}), not #{self}"
      end

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

      def validate_gate_when!(name, condition)
        return if condition.respond_to?(:call)

        raise ArgumentError, "gate :#{name} needs when: (something that responds to #call), got #{condition.inspect}"
      end

      # Shared by step and gate: both end up in the same raw_steps list, walked by
      # position, so a step and a gate with the same name collide with each other
      # too, not just within their own kind.
      def reserve_name!(name)
        name = name.to_sym
        return name unless raw_steps.any? { |s| s.name == name }

        raise ArgumentError, "step/gate :#{name} is already declared on #{self}"
      end
    end
  end
end
