# frozen_string_literal: true

# Lets Rails find spec/dummy as its own app root (config.ru or Gemfile is
# the marker it walks up looking for). This app is never actually served.
require_relative "config/environment"

run Rails.application
