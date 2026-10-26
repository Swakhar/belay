# frozen_string_literal: true

require "digest"

module Belay
  # Backs ctx.llm(..., cacheable: true) - see Context#llm. Not a general-
  # purpose cache for anything else in the gem; the only two callers are
  # Context#llm's own fetch-then-store pair.
  class CacheEntry < ApplicationRecord
    self.table_name = "belay_cache_entries"

    # SHA256 of [provider class name, model, prompt, schema].inspect - exact,
    # literal match only, the same .inspect-of-an-array-then-hash pattern
    # Workflow.workflow_version already uses. Deliberately NOT normalized
    # (schema/prompt symbol vs string key differences hash differently,
    # on purpose) - "exact-match cache" means exactly that, not "semantically
    # equivalent"; normalizing would be extra logic in service of a kind of
    # match this feature was never meant to offer.
    #
    # provider.class.name, not the model: string alone - a cached entry from
    # one provider should never satisfy a lookup under a different one
    # (swapping Belay.config.provider mid-lifecycle, or a FakeProvider in
    # tests sharing a database with a real one, shouldn't silently reuse
    # whatever the other provider once returned for an identical-looking call).
    def self.key_for(provider:, model:, prompt:, schema:)
      Digest::SHA256.hexdigest([provider.class.name, model, prompt, schema].inspect)
    end

    # nil on a miss OR an expired entry - the caller (Context#llm) can't tell
    # those apart from this return value alone, and doesn't need to: either
    # way, it makes a real provider call next. An expired row is left in
    # place, not deleted here - store! below will overwrite it on the next
    # successful call for the same key; there's no background sweep for rows
    # that are never asked for again, same as belay_steps keeps every row
    # forever rather than pruning anything.
    def self.fetch(provider:, model:, prompt:, schema:)
      entry = find_by(key: key_for(provider: provider, model: model, prompt: prompt, schema: schema))
      return nil if entry.nil? || entry.expires_at&.past?

      entry.increment!(:hits)
      entry.content
    end

    # upsert, not create!/update! - two callers racing to cache the same miss
    # (two workers asking the identical question for the first time at once)
    # both reach here; upsert's ON CONFLICT DO UPDATE means the second one
    # overwrites the first cleanly instead of raising on the unique index,
    # the same reasoning Run#acquire_lease! and friends already lean on
    # Postgres for elsewhere in this gem rather than a read-then-write race.
    #
    # ttl: defaults to the CURRENT Belay.config.cache_ttl at call time, not
    # whatever it was when an older entry for this key was first stored -
    # every store! reads it fresh, so changing the config takes effect on the
    # very next cache miss, not retroactively on rows already written.
    # rubocop:disable-next Metrics/ParameterLists
    def self.store!(provider:, model:, prompt:, schema:, content:, ttl: Belay.config.cache_ttl)
      key_value = key_for(provider: provider, model: model, prompt: prompt, schema: schema)
      now = Time.current
      upsert(
        { key: key_value, content: content, hits: 0, expires_at: ttl && (now + ttl), created_at: now, updated_at: now },
        unique_by: :key
      )
    end
  end
end
