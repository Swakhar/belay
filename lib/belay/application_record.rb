# frozen_string_literal: true

module Belay
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end
