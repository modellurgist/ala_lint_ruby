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
        --list-accepted      print every INHERENT_ declaration and every `ala:accept` comment, what
                             it covers, and the stale ones, then exit
        --help, -h           show this help

      Accepting a finding by hand, where the tool can't tell (a domain's own word, routing):
        # ala:accept r3                       the next line, for check r3
        # ala:accept r3,r5 lines=3 -- why     the next three lines, for two checks, with the reason
        <%# ala:accept r11 -- why %>          the same in ERB
      Accepted findings leave the score and are counted in the report. Words a lower abstraction
      owns as its domain's vocabulary are declared, not accepted: a constant named INHERENT_...
      (or a class-level @inherent_...) holds them, and R3 reads nothing inside it as product text.

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
        o.on("--list-accepted") { opts[:list_accepted] = true }
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
      report = AlaLint.analyze(root, **opts.except(:root, :list, :list_accepted, :help))
      return (out.puts(report.accepted_listing); 0) if opts[:list_accepted]
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
