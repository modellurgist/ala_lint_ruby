module AlaLint
  module Rules
    # R3: application literals below the composition. Numbers (other than the small ones arithmetic
    # needs), message text, sentences built by interpolation, validation messages, I18n lookups,
    # currency and unit codes, product-decision defaults, and the words a lower layer's template says.
    class Literals < Base
      PLAIN_NUMBERS = [0, 1, -1, 2].freeze
      BASES = [10, 100, 1000, 60, 24, 1024].freeze
      CODE_KEYS = %i[key_currency key_unit key_locale key_time_zone].freeze
      SKIP_CONTEXTS = %i[raise call_raise call_fail call_warn key_class key_data default].freeze
      LOGGER_CALLS = %i[warn info debug error fatal log].freeze

      def check
        return unless layered?
        units.each do |u|
          next unless below?(u)
          numbers(u)
          words(u) unless bottom?(u)
          defaults(u) unless u.template?
        end
      end

      private

      def numbers(u)
        seen = Set.new
        u.literals.each do |l|
          next if PLAIN_NUMBERS.include?(l.value) || SKIP_CONTEXTS.include?(l.context)
          next if BASES.include?(l.value) && arithmetic_line?(u, l.line)
          next if seen.include?([l.value, l.line])
          seen << [l.value, l.line]
          flag(:r3, u, l.line, "literal #{l.value} in #{u.name}#{method_name(l.method)} below the composition: hoist it if it's an application literal, keep it if intrinsic to the abstraction (R3)")
        end
      end

      def arithmetic_line?(u, line) = u.calls.any? { _1.line == line && %i[* / % fdiv divmod].include?(_1.name) }

      def words(u)
        u.strings.each do |s|
          next if SKIP_CONTEXTS.include?(s.context) || logged?(u, s.line) || s.inherent
          if s.context == :key_message
            flag(:r3, u, s.line, "validation message #{s.value.inspect} in #{u.name}: a form's words belong to the composition (R3); pass messages as configuration or use I18n keys the composition owns")
          elsif CODE_KEYS.include?(s.context)
            flag(:r3, u, s.line, "#{s.context.to_s.delete_prefix('key_')} #{s.value.inspect} in #{u.name}: a code the composition should configure once (R3)")
          elsif sentence?(s)
            kind = s.interpolated ? "sentence built by interpolation" : "message text"
            flag(:r3, u, s.line, "#{kind} #{s.value.inspect} in #{u.name}#{method_name(s.method)} below the composition: words a person reads belong to the composition (R3)")
          end
        end
        u.texts.each do |t|
          next unless t.words.size >= 2 && (t.value.match?(/[A-Z]/) || t.value.match?(/[.!?]\z/))
          flag(:r3, u, t.line, "markup text #{t.value.strip.inspect} in #{u.name}: words below the composition; let the page pass them in (R3)")
        end
        u.calls.each do |c|
          next unless %i[t translate].include?(c.name) && %i[none const].include?(c.receiver_kind) && (c.receiver_kind == :none || c.receiver_name == "I18n")
          next unless c.args.first.is_a?(Prism::StringNode) || c.args.first.is_a?(Prism::SymbolNode)
          flag(:r3, u, c.line, "#{u.name}#{method_name(c.method)} looks up I18n key #{c.args.first.unescaped.inspect} itself: a lower abstraction picking its own words (R3); the composition looks words up and passes them down")
        end
      end

      def sentence?(s)
        return false unless s.words.size >= 2 && s.value.include?(" ")
        return false if s.value.match?(/\A[\w\-:\/.\[\]#%,]+(\s[\w\-:\/.\[\]#%,]+)*\z/) && !s.value.match?(/[A-Z]/)
        s.value.match?(/[A-Z]/) || s.value.match?(/[.!?]\z/) || s.interpolated
      end

      def logged?(u, line) = u.calls.any? { _1.line == line && (LOGGER_CALLS.include?(_1.name) && _1.receiver_kind != :none || %i[raise warn fail].include?(_1.name)) }

      def defaults(u)
        u.methods.each do |m|
          m.keyword_defaults.each do |name, value|
            product = (value.is_a?(Prism::IntegerNode) && !PLAIN_NUMBERS.include?(value.value)) || value.is_a?(Prism::FloatNode) ||
                      (value.is_a?(Prism::StringNode) && !value.unescaped.empty?) || (value.is_a?(Prism::CallNode) && value.name == :new && value.receiver.is_a?(Prism::ConstantReadNode) && model.unit(value.receiver.name.to_s))
            next unless product
            what = value.is_a?(Prism::CallNode) ? "a peer as a default (R1)" : "a default that may be a product decision (R3, §5.5)"
            flag(:r3, u, value.location.start_line, "#{u.name}##{m.name} defaults #{name}: to #{value.slice}: #{what}; would another product want the same default?")
          end
        end
      end
    end
  end
end
