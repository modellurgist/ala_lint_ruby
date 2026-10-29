module AlaLint
  # The guide `bin/ala_lint --explain` prints: for the run a Config describes, what is scored, what is
  # only reported, and what still applies that no check reads. Rule wording follows
  # `ala_checklist_ruby.md`; the light-ALA conventions follow V59's DESIGN.md
  # (`ala_variants_elixir/v59-light-ala`), adapted to Ruby. No code is read.
  module Explain
    # [name, statement, what a reader still judges], from the checklist's rules and its
    # "What a linter can and cannot check"
    RULES = {
      r1: ["Edges drop",
           "every edge between abstractions drops to a lower layer, a knowledge dependency only on something significantly more abstract (§2.1.3).",
           "whether the declared boundaries are right, whether a same-layer call is cohesion or disguised peer coupling, and calls on an injected object, which Ruby doesn't type."],
      r2: ["Wires meet only at the top",
           "no class knows of the existence of state in any other class; what peers share is wired from above (§3.9).",
           "whether a shared store is a peer back-channel or a single-owner cache, and whether one mutable object reaches two peers through the wiring at run time."],
      r3: ["Application literals at the composition",
           "product-specific constants (thresholds, prices, labels, formats) live in the composition or a manifest it owns (§1.6.3, §2.4).",
           "whether a literal is an application literal (hoist it) or intrinsic (keep it), and whether a word is the product's or its domain's own."],
      r4: ["State with its owner",
           "state belongs in the instance whose concept it is; the app or a peer never keeps, reads or computes on it raw, and no getter hands it out (§3.9, §3.11.2).",
           "whether an instance field is the abstraction's own concept or a hidden cross-call channel whose state belongs to another concept or a wired State."],
      r5: ["No silent contracts",
           "no two modules know the meaning of data or a message, so no contract exists only as two matching literals (§7.8, §7.25).",
           "contracts no syntax tree shows, such as a data-action and its Stimulus method (JavaScript isn't read), or two ends agreeing through different literals."],
      r6: ["Nameability",
           "every abstraction names a learnable concept that separates the knowledge of different worlds (§2.1.1, §7.2.5).",
           "whether a name teaches a concept (an empty name like process2 passes), whether a carrier is a connection mechanism, and whether a lambda is a pull port or a hidden store."],
      r7: ["Earns its existence",
           "a separate abstraction is significantly more general than its caller and worth naming; prefer few meaningful abstractions to many trivial ones (§2.1.1).",
           "whether an abstraction hides a decision worth naming or is premature extraction, and whether a public-surface outlier is two concepts sharing a name."],
      r8: ["Reads as the requirements",
           "the top layer reads like the spec; config keys name what they configure, and state wires are shaped for a reader (§2.4).",
           "pure judgement, as is whether the wiring encodes the right spec; a linter can prompt R8, never score it."],
      r9: ["Ports by paradigm",
           "ports are typed by a programming paradigm, and an abstraction owns no interface except its own configuration (§2.3.4).",
           "whether an output reads as a fact or names its destination, whether a paradigm grew methods for one pair of classes, and duck-typed calls of a peer's methods."],
      r10: ["No shared entity", "no two features know the meaning of the same data (§3.8, §7.8).",
            "whether a shared type is shared meaning or a domain abstraction, whether an order or snapshot kept its identity keys, and whether a dataflow carries more than needed."],
      r11: ["Composition only",
            "the composition layers instantiate, configure and connect, with \"no normal programming language code such as assignments and if statements\" (§3.5).",
            "whether a flagged form is a departure the framework forces (routing, param decoding, a URL-to-step lookup), and whether a layer's name matches what it holds."]
    }.freeze

    # display order; %{check.key} fills in the run's threshold
    CHECKS = {
      r1: "an upward or cross-peer edge of any kind; without a layer map, a unit cycle",
      layer: "an @ala_layer tag naming an undeclared layer",
      subscribe: "a unit below the composition subscribing or broadcasting on a hardcoded topic",
      unassigned: "a unit matching no layer, which the layer-aware checks skip",
      r2: "class variables, globals, Thread.current, Current, a class-level @cache",
      r3: "numbers, words, I18n keys, currency codes, defaults below the composition",
      r4: "a composition field reassigned after construction, a mutable getter, a lock",
      r5: "an identifier string in two units, a label restating an amount, a built name",
      r6: "meaningless or role names (*Service), methods that only wrap an operator",
      tramp: "a parameter a public method never reads, only carries two hops down",
      ui_io: "a template below the composition that reaches a record model or a store",
      r7: "a private method named nowhere in the project",
      module_size: "a unit over %{module_size.max} lines",
      height: "a chain of hops between abstractions longer than %{height.max}",
      passthrough: "a public method that only renames another unit's method",
      clone: "the same logic in two units' methods, names aside (%{clone.min_nodes}+ nodes)",
      clone_inside: "the same logic twice inside one unit",
      public_surface: "a unit whose public ports are an outlier in its layer (floor %{public_surface.floor}, k %{public_surface.k})",
      module_avg: "units averaging under %{module_avg.min_avg} lines",
      ports_unwired: "a declared output no composition names (an R8 prompt)",
      r9: "peer mixins or abstract bases as ports, respond_to? tests, config lookups",
      ports: "a declared port missing from the class's header comment",
      r10: "a type read by two units of one layer; an association into another's rows",
      r10_aggregate: "a lower-layer type read by two units of a layer above it (§6.17.2)",
      r11: "branches (built names too), arithmetic, loops, handled data in a composition",
      app_share: "the composition layers' share of all functions, above %{app_share.max}",
      r11_share: "the share of composition functions holding logic (uncapped)"
    }.freeze

    LIGHT_RULES = [
      [5, "configuration and session values pass once, each as one value object (a Data.define); a new input is a new member, not a new parameter."],
      [6, "a rule grows by a configuration member or a method, never by a reshaped return value."],
      [8, "a value the domain needs is a required keyword argument, not a default."],
      [9, "a guard lives in the method that writes the data (the ActiveRecord writer, not only the controller) and refuses with an error result."],
      [10, "each page builds its parts in one composition root, a private method its actions call."],
      [11, "every builder of a config or session value object takes its required values plus keyword overrides, and tests build only through builders (no Ruby check yet)."],
      [12, "a session write sees a current record: the controller checks it is open before each action and reloads if not, and every writer refuses a closed one (no Ruby check yet)."]
    ].freeze

    WIDTH = 100

    def self.describes?(check) = CHECKS.key?(check)

    def self.text(config)
      not_adopted = Checks::RULES.select do |r|
        checks = Checks::ALL.select { _1.rule == r }
        r != :r8 && !checks.empty? && checks.all? { config.off?(_1.name) }
      end
      listed = ->(level) { CHECKS.keys.select { config.level(_1) == level }.group_by { Checks.fetch(_1).rule } }
      stated = []
      scored = checks_section(listed[:scored], config, stated)
      reported = checks_section(listed[:advisory], config, stated)
      judged = RULES.except(*not_adopted).map do |rule, (name, statement, judgement)|
        if stated.include?(rule) then wrap("  #{label(rule)}#{name}: #{judgement}", 6)
        else "#{wrap("  #{label(rule)}#{name}: #{statement}", 6)}\n#{wrap("      #{judgement[0].upcase}#{judgement[1..]}", 6)}"
        end
      end
      layers = config.layered? ? "on" : "none (the layer-aware checks find nothing)"
      tier = { default: "default", strict: "--strict", super_strict: "--super-strict" }.fetch(config.tier)
      [
        "ala_lint --explain: what this run scores, what it only reports, and what is left to a reader",
        wrap("  tier: #{tier}  preset: #{config.preset || 'none'}  layer map: #{layers}", 4),
        "", "SCORED IN THIS RUN", scored,
        "", "REPORTED, NOT SCORED", reported,
        "", "APPLIES, BUT NOT MACHINE-CHECKED", *judged, *light_lines(config),
        "", "Not adopted in this run: #{not_adopted.empty? ? 'none' : not_adopted.map(&:upcase).join(', ')}"
      ].join("\n")
    end

    # A rule's statement is printed where the rule first appears; a later section names it only.
    def self.checks_section(groups, config, stated)
      return "  (none)" if groups.empty?
      Checks::RULES.select { groups.key?(_1) }.map do |rule|
        name, statement, = RULES.fetch(rule)
        head = stated.include?(rule) ? "  #{label(rule)}#{name} (above)" : wrap("  #{label(rule)}#{name}: #{statement}", 6)
        stated << rule
        [head, *groups[rule].map { check_line(_1, config) }].join("\n")
      end.join("\n")
    end

    def self.check_line(check, config)
      text = CHECKS.fetch(check).gsub(/%\{(\w+)\.(\w+)\}/) { config.threshold($1.to_sym, $2.to_sym) }
      text += " (calls: #{config.threshold(:r11, :calls)})" if check == :r11 && config.threshold(:r11, :calls) != :all
      wrap("      #{check.to_s.ljust(15)}  #{text}", 23)
    end

    def self.light_lines(config)
      return [] unless config.preset == :light_ala
      ["  Light-ALA conventions (V59's rules; a checklist reading for light ALA, not Spray's ALA):",
       *LIGHT_RULES.map { |n, text| wrap("    rule #{n.to_s.ljust(4)}#{text}", 13) }]
    end

    def self.label(rule) = rule.to_s.upcase.ljust(4)

    def self.wrap(text, indent)
      first, *words = text.split(/ /, -1)
      words.each_with_object([first]) do |word, lines|
        if lines.last.length + 1 + word.length > WIDTH then lines << (" " * indent) + word
        else lines[-1] = "#{lines.last} #{word}"
        end
      end.join("\n")
    end
  end
end
