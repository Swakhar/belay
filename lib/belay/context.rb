# frozen_string_literal: true

module Belay
  # Passed as `ctx` to a step block (see README's Target API). Exposes the run's input
  # and prior steps' outputs as dotted method calls - ctx.invoice_id, ctx.extract - built
  # from two plain hashes, with no coupling to a specific Belay::Workflow class. Also
  # exposes step_idempotency_key: a plain reader, not a method_missing-served dynamic
  # key, since it's one fixed value for whichever step this Context was built for, not
  # a named entry in input or outputs. Belay::Executor is the only thing that passes a
  # real one (run_id + position, DESIGN_DECISIONS #3); it defaults to nil so Context
  # stays constructible standalone, as every existing spec already does.
  #
  # The freeze below is shallow: @input/@outputs are frozen hashes, but a value inside
  # them (e.g. ctx.extract returning a Hash) is not. If the executor ever reuses one
  # Context, or shares an output value, across more than one step, a step mutating
  # its own ctx.extract in place could corrupt what a later step reads. Not guarded
  # here - the executor's construction pattern (one Context per step? shared?) isn't
  # decided yet, and deep-freezing arbitrary step output is real added cost to pay for
  # a risk that depends on that undecided design.
  class Context
    attr_reader :input, :outputs, :step_idempotency_key

    def initialize(input: {}, outputs: {}, step_idempotency_key: nil)
      @input = symbolize_without_collision!(input, "input")
      @outputs = symbolize_without_collision!(outputs, "prior step output")
      @step_idempotency_key = step_idempotency_key
      validate_no_name_collisions!
      freeze
    end

    def method_missing(name, *args)
      return super unless args.empty? && !block_given?

      if @input.key?(name)
        @input[name]
      elsif @outputs.key?(name)
        @outputs[name]
      else
        super
      end
    end

    def respond_to_missing?(name, include_private = false)
      @input.key?(name) || @outputs.key?(name) || super
    end

    private

    def validate_no_name_collisions!
      name_overlap = @input.keys & @outputs.keys
      unless name_overlap.empty?
        raise ArgumentError, "input and prior step output names collide: #{name_overlap.inspect} - rename one"
      end

      # self.class.method_defined?, not respond_to?: respond_to? would consult
      # respond_to_missing? above, which checks @input/@outputs themselves - every key
      # would "collide" with its own dynamic accessor. method_defined? only sees real,
      # statically-defined methods: #input/#outputs (attr_reader) and inherited
      # Object/Kernel ones (class, hash, freeze, send, ...) - not method_missing-served
      # ones. A key literally named "input" would otherwise shadow the reader above
      # with no error.
      reserved = (@input.keys + @outputs.keys).select { |key| self.class.method_defined?(key) }
      return if reserved.empty?

      raise ArgumentError,
            "input/output name(s) #{reserved.inspect} collide with an existing method on #{self.class} - rename them"
    end

    def symbolize_without_collision!(hash, label)
      symbolized = hash.transform_keys(&:to_sym)
      if symbolized.size != hash.size
        raise ArgumentError, "two #{label} keys collapse to the same name once symbolized: #{hash.keys.inspect}"
      end

      symbolized.freeze
    end
  end
end
