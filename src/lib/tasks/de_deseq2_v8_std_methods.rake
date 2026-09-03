# frozen_string_literal: true

namespace :de_deseq2_v8_std_methods do
  desc 'Align v8 DESeq2 StdMethod command_json with de.v8.py CLI (--write-metadata, --group, --group-2, --batch)'
  task upsert: :environment do
    require_relative '../de_deseq2_v8_std_methods'
    summary = DeDeseq2V8StdMethods.upsert!
    puts summary.inspect
  end
end
