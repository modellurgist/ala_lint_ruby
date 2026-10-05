module AlaLint
  # Every check the linter runs: the checklist rule it serves, its tier (what scores it by default),
  # its weight in the score, and any threshold a team may retune. The tiers follow the Ruby edition's
  # "Enforcement tiers" table.
  module Checks
    Check = Data.define(:name, :rule, :tier, :weight, :description, :thresholds)

    TIERS = {
      required: "scored by default; a violation fails --min-score",
      advisory: "reported by default; scored under --strict; --enforce CHECK to promote one",
      aspirational: "reported by default; scored only under --super-strict",
      reported: "never scored by a tier; --enforce CHECK to score one"
    }.freeze

    ALL = [
      Check.new(:r1, :r1, :required, 3, "every edge between abstractions drops: no peer, upward or cyclic reference, instantiation, superclass or mixin", {}),
      Check.new(:r2, :r2, :required, 3, "no shared mutable state between peers: class variables, globals, Thread.current, Current attributes, class-level state below the composition", {}),
      Check.new(:r3, :r3, :required, 1, "application literals live at the composition: numbers, words, I18n keys, validation messages, product defaults below it", {}),
      Check.new(:r4, :r4, :required, 2, "state lives with its owner: no fields reassigned after construction at the top, no getters handing out mutable state, no locks or instance_variable_get across objects", {}),
      Check.new(:r5, :r5, :required, 3, "no silent contracts: the same identifier string in two units, a label restating a configured amount, dynamic method names agreed across classes", {}),
      Check.new(:r6, :r6, :required, 1, "every abstraction names a learnable concept: no meaningless or role names, no primitive wrappers", {}),
      Check.new(:r9, :r9, :required, 3, "ports by paradigm: no peer mixin as an interface, no abstract base class as a port, no duck-typed peer messages, no container, locator or global config lookup below the composition", {}),
      Check.new(:r10, :r10, :required, 3, "no shared entity: a data type read by two units of one peer-forbidden layer; an association that walks into another feature's table", {}),
      Check.new(:layer, :r1, :required, 3, "layer validity: a tag naming an undeclared layer", {}),

      Check.new(:r7, :r7, :advisory, 1, "unearned abstraction: a dead private method, or a trivial single-use one", {}),
      Check.new(:module_size, :r7, :advisory, 1, "a unit over N lines", { max: 500 }),
      Check.new(:height, :r7, :advisory, 1, "hops between abstractions past N", { max: 5 }),
      Check.new(:passthrough, :r7, :advisory, 1, "a public method that only renames another unit's method", {}),
      Check.new(:tramp, :r6, :advisory, 1, "a parameter a public method never reads, only carries two hops down (R6 should)", {}),
      Check.new(:subscribe, :r1, :advisory, 1, "a unit below the composition subscribing to, or broadcasting on, a topic it fixes", {}),
      Check.new(:ports, :r9, :advisory, 1, "a declared port missing from the class's header comment", {}),
      Check.new(:ui_io, :r6, :advisory, 1, "a UI component below the composition that reaches a store", {}),
      Check.new(:r10_aggregate, :r10, :advisory, 1, "a lower-layer data type read by two units of a peer-forbidden layer above it", {}),

      Check.new(:r11, :r11, :aspirational, 1, "no logic in a composition layer: branches (routing exempt), arithmetic, iteration, handled data, template logic", {}),
      Check.new(:public_surface, :r9, :aspirational, 1, "a unit with more than N public methods", { max: 12 }),

      Check.new(:app_share, :r11, :reported, 1, "the composition layers' share of all functions", { max: 0.2 }),
      Check.new(:module_avg, :r7, :reported, 1, "units averaging under N lines", { min_avg: 100 }),
      Check.new(:unassigned, :r1, :reported, 1, "a unit matching no layer: the layer-aware checks skip it", {}),
      Check.new(:ports_unwired, :r8, :reported, 1, "a declared output no composition names", {}),
      Check.new(:r11_share, :r11, :reported, 1, "share of composition functions holding logic", {})
    ].freeze

    BY_NAME = ALL.to_h { [_1.name, _1] }.freeze
    RULES = %i[r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11].freeze
    NEEDS_LAYERS = %i[r3 r10 r11].freeze

    def self.fetch(name) = BY_NAME.fetch(name.to_sym) { raise ArgumentError, "unknown check #{name}" }

    def self.listing
      out = +"ALA checks and how each is scored. Change any of this in a `.ala_lint.rb` hash\n" \
            "(checks: { r7: :scored, height: { max: 4 }, r11: :off }) or per run with the flags shown.\n"
      TIERS.each do |tier, when_scored|
        out << "\n#{tier.to_s.upcase.ljust(12)} (#{when_scored})\n"
        ALL.select { _1.tier == tier }.each do |c|
          flag = c.thresholds.map { |k, v| "--set #{c.name}.#{k}=#{v}" }.join(" ")
          out << format("  %-15s %s%s\n", c.name, c.description, flag.empty? ? "" : "  [#{flag}]")
        end
      end
      out << "\nNOT MACHINE-SCORED (a human reads for these)\n" \
             "  r8              reads as the requirements\n" \
             "  r9              the rest of R9 (outputs announce, no shared DTOs, duck-typed messages the tool can't see)\n" \
             "\nTurn any check off with --disable CHECK, or checks: { CHECK: :off } in the file.\n"
    end
  end
end
