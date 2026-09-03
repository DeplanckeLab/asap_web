# frozen_string_literal: true

namespace :de_python_unbuffered_v8_std_methods do
  desc 'Use python -u for v8 DE StdMethods so ErrorJSON reaches exec.out'
  task upsert: :environment do
    require_relative '../de_python_unbuffered_v8_std_methods'
    summary = DePythonUnbufferedV8StdMethods.upsert!
    puts summary.inspect
  end
end
