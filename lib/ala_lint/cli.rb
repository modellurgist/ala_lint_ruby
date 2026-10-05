require "optparse"

module AlaLint
  # The command line: the same flags as `mix ala.lint`, with `.ala_lint.rb` as the durable settings.
  class CLI
    USAGE = <<~TXT
      ala_lint [PATHS...] [options]

      Analyze Ruby and ERB under the given paths (default: app lib config/routes.rb, relative to
      --root or the current directory) against the ALA Checklist, Ruby and Rails edition, and print
      findings plus a design-health score.

      Common:
        --root DIR           the project root holding .ala_lint.rb (default: .)
        --config FILE        a settings file other than ROOT/.ala_lint.rb
        --min-score N        exit 1 if the score is below N (the CI gate)
        --strict             score the obtainable advisory checks too
        --super-strict       --strict, plus the aspirational checks (R11, public_surface)
        --require-layers     exit 1 if any unit matches no layer
        --limit N            show up to N findings per list (default 40)
        --format text|json   output format (default text)
        --list-checks        print every check with its tier and threshold, then exit
        --help, -h           show this help

      Per-check overrides:
        --enforce CHECK      promote one check to scored (repeatable)
        --disable CHECK      turn one check off (repeatable; the report says so)
        --set KEY=VALUE      retune a threshold: height.max, module_size.max, public_surface.max,
                             app_share.max, module_avg.min_avg (repeatable)
    TXT

    def self.run(argv, out: $stdout, err: $stderr)
      opts = { enforce: [], disable: [], set: {}, paths: [] }
      parser = OptionParser.new do |o|
        o.on("--root DIR") { opts[:root] = _1 }
        o.on("--config FILE") { opts[:config] = _1 }
        o.on("--min-score N", Integer) { opts[:min_score] = _1 }
        o.on("--strict") { opts[:tier] = :strict }
        o.on("--super-strict") { opts[:tier] = :super_strict }
        o.on("--require-layers") { opts[:require_layers] = true }
        o.on("--limit N", Integer) { opts[:limit] = _1 }
        o.on("--format F") { opts[:format] = _1.to_sym }
        o.on("--list-checks") { opts[:list] = true }
        o.on("--enforce CHECK") { opts[:enforce] << _1 }
        o.on("--disable CHECK") { opts[:disable] << _1 }
        o.on("--set KV") { k, v = _1.split("=", 2); opts[:set][k] = v.include?(".") ? v.to_f : v.to_i }
        o.on("-h", "--help") { opts[:help] = true }
      end
      begin
        opts[:paths] = parser.parse(argv)
      rescue OptionParser::ParseError => e
        err.puts "ala_lint: #{e.message}"
        err.puts USAGE
        return 2
      end
      return (out.puts(USAGE); 0) if opts[:help]
      return (out.puts(Checks.listing); 0) if opts[:list]
      (opts[:enforce] + opts[:disable]).each { Checks.fetch(_1) }
      opts[:set].each_key { |k| Checks.fetch(k.split(".").first) }

      root = File.expand_path(opts[:root] || ".")
      report = AlaLint.analyze(root, **opts.except(:root, :list, :help))
      out.puts(report.model.config.format == :json ? report.to_json : report.to_text)
      return 1 unless report.passes_min_score?
      return 1 unless report.requires_layers_ok?
      0
    rescue ArgumentError => e
      err.puts "ala_lint: #{e.message}"
      2
    end
  end
end
