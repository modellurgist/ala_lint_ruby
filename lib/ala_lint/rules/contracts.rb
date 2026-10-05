module AlaLint
  module Rules
    # R5: silent contracts the call graph can't show. The same identifier-like string in two units
    # (unless both are the composition, which is one abstraction), a label quoting a configured
    # amount, and a method name built from a string that another class must also build.
    class Contracts < Base
      IDENT = /\A[A-Za-z][\w\-.:\/]{2,39}\z/
      STRING_OPS = %i[end_with? start_with? delete_prefix delete_suffix sub gsub sub! gsub! split join include? match? match scan tr index rindex ljust rjust center chomp].freeze
      COMMON = %w[utf-8 UTF-8 text/html application/json text/vnd.turbo-stream.html _top _self GET POST PATCH PUT DELETE development test production true false nil].freeze

      def check
        duplicated_identifiers
        money_labels
        dynamic_names
      end

      private

      def duplicated_identifiers
        occurrences = Hash.new { |h, k| h[k] = [] }
        units.each do |u|
          u.strings.each do |s|
            next if s.interpolated || !IDENT.match?(s.value) || COMMON.include?(s.value)
            next if s.value.length < 5 && !s.value.match?(/[_\-.:\/]/)
            next if s.context.to_s.match?(/\Akey_(class|data|method|as|via|to|controller|action|on)\z/) || %i[call_require call_require_relative call_render key_partial key_layout key_template].include?(s.context)
            next if u.script? && u.name.end_with?("routes")
            next if s.context.to_s.start_with?("call_") && STRING_OPS.include?(s.context.to_s.delete_prefix("call_").to_sym)
            occurrences[s.value] << [u, s]
          end
        end
        occurrences.each do |value, occ|
          involved = occ.map(&:first).uniq
          next if involved.size < 2
          next if layered? && involved.all? { composition?(_1) }
          next if layered? && involved.all? { _1.layer.nil? }
          u, s = occ.first
          others = involved.reject { _1 == u }.map(&:name).first(3).join(", ")
          flag(:r5, u, s.line, "#{value.inspect} also appears in #{others}: a name two units agree on (R5, §7.8); keep it in the composition and pass it to both ends, or make both ends one abstraction")
        end
      end

      def money_labels
        cents = units.flat_map { |u| u.literals.map(&:value) }.select { _1.is_a?(Integer) }.to_set
        units.each do |u|
          (u.strings + u.texts).each do |s|
            s.value.scan(/\$(\d+)\.(\d\d)/) do |d, c|
              amount = d.to_i * 100 + c.to_i
              next unless cents.include?(amount)
              flag(:r5, u, s.line, "#{s.value.inspect} in #{u.name} restates a configured amount (#{amount} cents): change the fee and the label lies (R5); build the label from the value")
            end
          end
        end
      end

      def dynamic_names
        units.each do |u|
          next if bottom?(u) || u.template?
          u.calls.each do |c|
            next unless %i[send public_send __send__ method].include?(c.name)
            next unless c.args.first.is_a?(Prism::InterpolatedStringNode) || c.args.first.is_a?(Prism::InterpolatedSymbolNode)
            flag(:r5, u, c.line, "#{u.name}#{method_name(c.method)} calls a method by a name built from a string: a contract no signature shows (R5); dispatch through a port or a table the composition supplies")
          end
        end
      end
    end
  end
end
