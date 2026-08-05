require_relative "../reference_data_compare"

namespace :reference_data do
  desc "Export reference model snapshot (use LABEL=... OUT=... [MODELS=... INCLUDE_TIMESTAMPS=1])"
  task export: :environment do
    label = ENV["LABEL"]
    out = ENV["OUT"]

    if label.to_s.strip.empty? || out.to_s.strip.empty?
      puts "Usage:"
      puts "  bin/rake reference_data:export LABEL=dev OUT=/tmp/asap-dev.json"
      puts "Optional:"
      puts "  MODELS=Step,StdMethod,DockerImage,DockerBuild,Version,Speed"
      puts "  INCLUDE_TIMESTAMPS=1"
      exit 1
    end

    argv = ["export", "--label", label, "--out", out]
    argv += ["--models", ENV["MODELS"]] if ENV["MODELS"].to_s.strip != ""
    argv << "--include-timestamps" if ENV["INCLUDE_TIMESTAMPS"].to_s == "1"

    CompareReferenceData.new.run(argv)
  end

  desc "Compare two snapshots (use LEFT=... RIGHT=... [OUT=... MODELS=...])"
  task compare: :environment do
    left = ENV["LEFT"]
    right = ENV["RIGHT"]

    if left.to_s.strip.empty? || right.to_s.strip.empty?
      puts "Usage:"
      puts "  bin/rake reference_data:compare LEFT=/tmp/asap-dev.json RIGHT=/tmp/asap-prod.json"
      puts "Optional:"
      puts "  OUT=/tmp/asap-diff-report.json"
      puts "  MODELS=Step,StdMethod,DockerImage,DockerBuild,Version,Speed"
      exit 1
    end

    argv = ["compare", "--left", left, "--right", right]
    argv += ["--out", ENV["OUT"]] if ENV["OUT"].to_s.strip != ""
    argv += ["--models", ENV["MODELS"]] if ENV["MODELS"].to_s.strip != ""

    CompareReferenceData.new.run(argv)
  end
end
