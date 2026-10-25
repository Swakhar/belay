# frozen_string_literal: true

require "json_schemer"

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
    # Raised when schema: was given to ctx.llm but the provider's response doesn't
    # match it. errors is JSONSchemer's own list of validation error hashes, not a
    # single summarized string, so a caller can inspect exactly what failed.
    class SchemaValidationError < Error
      attr_reader :errors

      def initialize(errors:, content:, schema:)
        @errors = errors
        messages = errors.map { |e| e["error"] }.join("; ")
        super("ctx.llm's response did not match schema: #{messages} (content: #{content.inspect}, " \
              "schema: #{schema.inspect})")
      end
    end

    attr_reader :input, :outputs, :step_idempotency_key

    # model_override: is Run#replay(model:)'s whole mechanism - nil for every
    # ordinary run (the common case: #llm just uses whatever model: the step's
    # own block passed). Executor::StepRunner#build_context is the only real
    # caller that ever passes one, reading it off @run.replay_model.
    def initialize(input: {}, outputs: {}, step_idempotency_key: nil, model_override: nil)
      @input = symbolize_without_collision!(input, "input")
      @outputs = symbolize_without_collision!(outputs, "prior step output")
      @step_idempotency_key = step_idempotency_key
      @model_override = model_override
      # Mutated in place by #llm below, not reassigned - this object freezes itself
      # at the end of #initialize, which would make `@llm_metadata = ...` raise
      # FrozenError from inside #llm. Mutating the Hash this ivar already points to
      # is a different, allowed thing: freezing Context doesn't freeze objects it
      # merely references.
      @llm_metadata = {}
      validate_no_name_collisions!
      freeze
    end

    # Calls Belay.config.provider, validates the response against schema: (if given)
    # with JSONSchemer, and returns response.content - a step block's return value
    # becomes its checkpointed output, so #llm's return value IS the step's output,
    # not a wrapper around it.
    #
    # Validated here, provider-agnostically, rather than inside each Provider:
    # AnthropicProvider's own schema: already asks Anthropic's API to constrain its
    # output, but FakeProvider enforces nothing at all - without this, a spec's
    # scripted response could silently not match the schema: it claims to, and
    # nothing would catch that until production. This is the one place that's true
    # for every provider.
    #
    # schema: must use string keys for its own keywords (symbol-keyed schemas are
    # deep-stringified below first) and set additionalProperties: false on every
    # object, per Anthropic's own requirement for the same schema when a provider
    # like AnthropicProvider forwards it as output_config.format.schema.
    # model: passed here is a default, not the final word - model_override
    # (set only on a replay's shadow run) takes precedence, so a replayed
    # llm_call step actually calls the overriding model without the workflow
    # body itself needing to know anything about replay.
    def llm(model:, prompt:, schema: nil)
      effective_model = @model_override || model
      provider = resolve_provider!
      response = provider.call(model: effective_model, prompt: prompt, schema: schema)

      # Recorded before validating, not after: provider.call above already made a
      # real, billed request by the time we know whether its content matches
      # schema:. A response that fails validation raises below and this step's
      # row ends up "failed" - run_attempt's dual-merge (see executor.rb) persists
      # whatever's in @llm_metadata onto that failed row regardless, which only
      # works if the merge already happened before the raise, not after it.
      fields = response.to_h.slice(:model, :input_tokens, :output_tokens, :cost_cents, :latency_ms)
      # input: prompt, not :prompt - matches belay_steps' own column name exactly
      # (same reasoning as every other key here: extra_step_attrs below merges
      # this whole hash straight into step.update!, with no translation step in
      # between), so the dashboard's run page (feat(dashboard): run page with
      # step timeline, prompt, response, tokens and cost) has something real to
      # show as "prompt" - the exact value passed to ctx.llm, not a summary of it.
      @llm_metadata.merge!(provider: provider.class.name, input: prompt, **fields)

      validate_against_schema!(response.content, schema) if schema
      response.content
    end

    # {} if #llm was never called this step - nothing to persist onto the step row,
    # same as any step that made no provider call. Frozen dup, same reasoning as
    # Workflow#steps/#inputs and FakeProvider#calls: a caller reaching in and
    # mutating this would corrupt what StepRunner later reads to update the row.
    def llm_metadata
      @llm_metadata.dup.freeze
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

    def resolve_provider!
      Belay.config.provider || raise(Error, "Belay.config.provider is not set - configure one before calling " \
                                            "ctx.llm, e.g. Belay.configure { |c| c.provider = " \
                                            "Belay::AnthropicProvider.new }")
    end

    def validate_against_schema!(content, schema)
      document = json_normalize(content)
      schemer = JSONSchemer.schema(json_normalize(schema))
      return if schemer.valid?(document)

      raise SchemaValidationError.new(errors: schemer.validate(document).to_a, content: content, schema: schema)
    end

    # Hash#deep_stringify_keys only converts hash keys, not a bare Symbol used as a
    # VALUE - required: [:total_cents] (a real, common JSON Schema shape, not an
    # edge case) comes through untouched, so "total_cents" (the stringified
    # document's actual key) never matches :total_cents. JSON itself has no symbol
    # type; normalizing every symbol anywhere in the structure, key or value, is
    # what makes a Ruby-idiomatic symbol-keyed/valued schema or FakeProvider script
    # behave the same as what the real API actually returns (plain JSON.parse'd
    # strings throughout).
    def json_normalize(value)
      case value
      when Hash
        value.to_h { |k, v| [k.to_s, json_normalize(v)] }
      when Array
        value.map { |v| json_normalize(v) }
      when Symbol
        value.to_s
      else
        value
      end
    end

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
