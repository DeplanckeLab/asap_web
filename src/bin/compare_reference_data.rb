#!/usr/bin/env ruby
# frozen_string_literal: true

# Ensure Gemfile constraints are activated before requiring gems like json.
begin
  require "bundler/setup"
rescue LoadError
  # Allow execution in contexts where bundler is unavailable.
end

require_relative "../lib/reference_data_compare"
CompareReferenceData.new.run(ARGV)
