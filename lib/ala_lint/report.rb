require "json"

module AlaLint
  # Findings plus the model's size, turned into the two scores the Elixir linter reports (a weighted
  # density, and the share of functions with no scored finding), the rules-met count, and text/JSON.
  class Report
    RULE_NAMES = { r1: "R1 peer coupling / cycles", r2: "R2 shared mutable state", r3: "R3 misplaced application literal",
                   r4: "R4 hidden state", r5: "R5 silent contracts", r6: "R6 nameability", r7: "R7 unearned abstractions",
                   r9: "R9 owned interfaces / endpoints", r10: "R10 shared entity", r11: "R11 logic in the composition" }.freeze

    attr_reader :model, :findings, :scored, :advisory, :accepted

    def initialize(model, findings, accepted = [])
      @model = model
      @accepted = accepted
      @config = model.config
      @findings = findings.sort_by { [-weight(_1), _1.check.to_s, _1.file, _1.line] }
      @scored, @advisory = @findings.partition { @config.scored?(_1.check) }
    end

    def check(name) = Checks.fetch(name)
    def weight(f) = check(f.check).weight
    def functions = model.functions
    def loc = model.units.sum(&:loc)
    def weighted = @scored.sum { weight(_1) }
    def density = functions.zero? ? 0.0 : weighted * 100.0 / functions
    def score = [[100 - density, 0].max, 100].min.round
    def grade(s = score) = s >= 90 ? "A" : s >= 75 ? "B" : s >= 60 ? "C" : s >= 40 ? "D" : "F"

    def offending_functions
      @scored.map { |f| owner = model.unit(f.unit); m = owner&.method_at(f.line); [f.unit, m ? m.name : (owner&.template? ? :template : nil)] }.reject { _1[1].nil? }.uniq.size
    end

    def unit_level_findings = @scored.count { |f| owner = model.unit(f.unit); owner && !owner.template? && owner.method_at(f.line).nil? }
    def breadth = functions.zero? ? 100 : [[100 - offending_functions * 100.0 / functions, 0].max, 100].min.round

    def by_check = @findings.group_by(&:check).transform_values(&:size)

    def rules
      Checks::RULES.to_h do |r|
        checks = Checks::ALL.select { _1.rule == r }.map(&:name)
        s = @scored.count { checks.include?(_1.check) }
        a = @advisory.count { checks.include?(_1.check) }
        state = if r == :r8 || (Checks::NEEDS_LAYERS.include?(r) && !model.layered?) then :unchecked
                elsif s.positive? then :not_met
                else :met
                end
        [r, { state: state, scored: s, advisory: a }]
      end
    end

    def height = @findings.find { _1.check == :height }&.message&.[](/height (\d+)/, 1)&.to_i

    def coverage
      return nil unless model.layered?
      assigned, unassigned = model.units.partition(&:layer)
      { assigned: assigned.size, total: model.units.size, pct: model.units.empty? ? 100 : (assigned.size * 100.0 / model.units.size).round, unassigned: unassigned.map(&:name) }
    end

    def passes_min_score? = @config.min_score.nil? || score >= @config.min_score
    def requires_layers_ok? = !@config.require_layers || coverage.nil? || coverage[:unassigned].empty?

    def acceptances = model.acceptances
    def acceptance_for(finding) = acceptances.find { _1.covers?(finding) }
    def unused_acceptances = acceptances.reject { |a| @accepted.any? { a.covers?(_1) } }

    # Every reviewer's acceptance, what it covers, and the ones that cover nothing (stale, or a check
    # that no longer fires there).
    def inherent_declarations = model.units.flat_map { |u| u.inherent_declarations.map { |name, line| [u, name, line] } }

    def accepted_listing
      out = +""
      unless inherent_declarations.empty?
        out << "Inherent text declared (#{inherent_declarations.size}; R3's domain-vocabulary exception, the words are the abstraction's own):\n"
        inherent_declarations.each { |u, name, line| out << "  #{model.relative(u.file)}:#{line}  #{u.name}::#{name}\n" }
      end
      return out + "No ala:accept comments.\n" if acceptances.empty?
      out << "Accepted by hand (#{@accepted.size} finding(s) under #{acceptances.size} comment(s)):\n"
      acceptances.each do |a|
        covered = @accepted.select { a.covers?(_1) }
        out << "  #{a.file}:#{a.line}  #{a.checks.join(',')}  lines #{a.range}#{a.reason.empty? ? '' : "  -- #{a.reason}"}\n"
        covered.each { out << "      ↳ [#{_1.check}] line #{_1.line}: #{_1.message}\n" }
        out << "      ↳ covers nothing: stale, or the check no longer fires here\n" if covered.empty?
      end
      out
    end

    def to_h
      { score: score, accepted: @accepted.map { |f| f.to_h.merge(accepted_by: acceptance_for(f).to_h) },
        acceptances: acceptances.map(&:to_h), grade: grade, breadth: breadth, breadth_grade: grade(breadth), weighted: weighted, functions: functions, loc: loc,
        units: model.units.size, rules: rules, coverage: coverage, by_check: by_check, params: @config.params,
        findings: @findings.map { _1.to_h.merge(scored: @config.scored?(_1.check), weight: weight(_1)) } }
    end

    def to_json(*) = JSON.pretty_generate(to_h)

    def to_text
      limit = @config.limit
      r = rules
      checked = r.values.count { _1[:state] != :unchecked }
      met = r.values.count { _1[:state] == :met }
      strictly = r.values.count { _1[:state] == :met && _1[:advisory].zero? }
      out = +""
      out << unassigned_banner
      out << "── ALA Checklist (R1–R11), Ruby and Rails edition ────────────────────────\n"
      out << "units: #{model.units.size} (#{model.templates.size} templates)   functions: #{functions}   LOC: #{loc}\n"
      out << "abstraction height: #{height || 'within max'}   layer coverage: #{coverage_line}\n\n"
      out << "Checklist rules met: #{met} of #{checked} checked (11 in the checklist; R8 is judgement)\n"
      out << "  with no finding at all, advisory included: #{strictly} of #{checked}\n"
      out << "  — a count, not a density: one finding in a large codebase still leaves its rule unmet.\n"
      out << "Accepted by hand: #{@accepted.size} finding(s) under #{acceptances.size} ala:accept comment(s)#{unused_acceptances.empty? ? '' : ", #{unused_acceptances.size} covering nothing"}; --list-accepted prints them\n" unless acceptances.empty?
      out << "  " << r.map { |k, v| "#{k.to_s.upcase} #{v[:state] == :met ? 'met' : v[:state] == :not_met ? "NOT met (#{v[:scored]})" : 'unchecked'}" }.join("  ") << "\n\n"
      out << "Degree of function compliance: #{score}/100  (grade #{grade})\n"
      out << "  — 100 minus the weighted-violation load per 100 functions; a few dense units can drag it.\n"
      out << "  weighted violations: #{weighted}   load per 100 functions: #{density.round(2)}   per 1000 LOC: #{loc.zero? ? 0 : (weighted * 1000.0 / loc).round(2)}\n\n"
      out << "Count of compliant functions: #{functions - offending_functions} / #{functions}  (#{breadth}% → grade #{grade(breadth)})\n"
      out << "  — functions with zero scored findings; unit-level findings (no owning method): #{unit_level_findings}\n\n"
      out << "By rule (weight):\n"
      RULE_NAMES.each do |rule, name|
        checks = Checks::ALL.select { _1.rule == rule }.map(&:name)
        n = @scored.count { checks.include?(_1.check) }
        w = Checks::ALL.find { _1.rule == rule && _1.tier == :required }&.weight || Checks::ALL.find { _1.rule == rule }.weight
        out << format("  %-36s %3d  (×%d)\n", name, n, w)
      end
      out << "\nFindings (scored, most severe first):\n"
      out << (scored.empty? ? "  none 🎉\n" : lines(scored, limit))
      out << "\nAdvisory (reported, NOT scored at this tier):\n"
      out << (advisory.empty? ? "  none\n" : lines(advisory, limit))
      out << "  promote any of these with --enforce CHECK, --strict, or --super-strict.\n"
      out << params_section
      out << "\nR8 (reads as the requirements) is judgement, not checked here: a high score is necessary,\n" \
             "not sufficient. See ala_checklist_ruby.md, \"What a linter can and cannot check\".\n"
      out
    end

    private

    def lines(list, limit)
      shown = list.first(limit).map { "  [#{_1.check}] #{_1.file}:#{_1.line}  #{_1.message}\n" }.join
      more = list.size > limit ? "  … and #{list.size - limit} more (raise --limit to see them)\n" : ""
      shown + more
    end

    def coverage_line
      c = coverage
      return "(no layer map — declare layers in .ala_lint.rb to assign units)" unless c
      tail = c[:unassigned].empty? ? "" : "; unassigned: #{c[:unassigned].first(6).join(', ')}#{c[:unassigned].size > 6 ? " … +#{c[:unassigned].size - 6}" : ''}"
      "#{c[:assigned]}/#{c[:total]} units (#{c[:pct]}%)#{tail}"
    end

    def unassigned_banner
      c = coverage
      return "" if c.nil? || c[:unassigned].empty?
      "!! WARNING: #{c[:unassigned].size} unit(s) match no layer; R1 altitude, R3, R10 and R11 skip them,\n" \
      "!! so this score covers less than the codebase:\n" + c[:unassigned].first(10).map { "!!   #{_1}\n" }.join + "\n"
    end

    def params_section
      p = @config.params
      integrity = +""
      integrity << "\n  disabled (NOT scored): #{p[:disabled].join(',')}" unless p[:disabled].empty?
      integrity << "\n  downgraded to advisory: #{p[:downgraded].join(',')}" unless p[:downgraded].empty?
      "\nParameters (effective):\n  root: #{p[:root]}   paths: #{p[:paths].join(' ')}   tier: #{p[:tier]}\n" \
      "  layers: #{p[:layers]}   identity_models: #{p[:identity_models].empty? ? '(none)' : p[:identity_models].join(',')}\n" \
      "  enforce: #{p[:enforce].empty? ? '(none)' : p[:enforce].join(',')}#{integrity}\n" \
      "  thresholds: #{p[:thresholds].map { |k, v| "#{k}=#{v}" }.join(' ')}\n" \
      "  fixed heuristics: R3 skips 0/1/-1/2 and bases beside * or /; R5 identifier strings 3–40 chars; R6 wrappers are one operator over parameters\n"
    end
  end
end
