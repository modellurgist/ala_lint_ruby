module AlaLint
  module Rules
    # R7's advisories: dead private methods, pass-throughs, unit size, the average size, and a public
    # surface wide for its layer, reported as a prompt for R6/R7 judgement.
    class Minimality < Base
      def check
        units.each do |u|
          next if u.template?
          dead_privates(u)
          passthroughs(u)
          size(u)
        end
        surfaces
        average
      end

      private

      # A private method nobody names anywhere, as a call, a symbol (`before_action :x`, `&:x`,
      # `method(:x)`), or a dynamic `send`. Project-wide, because mixins and subclasses call
      # privates across units.
      def dead_privates(u)
        named = named_everywhere
        return if @dynamic
        u.methods.select { _1.visibility == :private && !_1.singleton }.each do |m|
          base = m.name.to_s.delete_suffix("=").to_sym
          next if named.include?(m.name) || named.include?(base) || %i[initialize method_missing respond_to_missing? inspect to_s].include?(m.name)
          flag(:r7, u, m.line, "#{u.name}##{m.name} is private and never called: dead code (R7)")
        end
      end

      def named_everywhere
        @named ||= begin
          @dynamic = units.any? { |x| x.calls.any? { %i[send public_send __send__ define_method].include?(_1.name) && !_1.args.first.is_a?(Prism::SymbolNode) } }
          units.flat_map { |x| x.calls.map(&:name) + x.symbols.map(&:to_sym) }.to_set
        end
      end

      # A public method that only renames another unit's method, with the same arguments: a hop that
      # hides no decision. Delegation over a field is the shape that replaces inheritance (§7.16), so
      # it is named as such.
      def passthroughs(u)
        u.methods.select { _1.visibility == :public && !_1.singleton && !_1.name.to_s.end_with?("?") && _1.name != :initialize }.each do |m|
          body = m.simple_body
          next unless body.is_a?(Prism::CallNode) && body.name != :new
          args = body.arguments&.arguments || []
          next unless args.size == m.params.size && args.zip(m.params).all? { |a, p| a.is_a?(Prism::LocalVariableReadNode) && a.name == p }
          next if body.block
          case body.receiver
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            call = m.calls.find { _1.line == body.location.start_line && _1.name == body.name }
            next unless call&.resolved && call.resolved != u.name
            flag(:passthrough, u, m.line, "#{u.name}##{m.name} only renames #{call.resolved}.#{body.name}: a hop that hides no decision (R7)")
          when Prism::InstanceVariableReadNode
            next if m.params.empty?
            flag(:passthrough, u, m.line, "#{u.name}##{m.name} delegates to #{body.receiver.name}.#{body.name} unchanged: expected where delegation replaces inheritance (§7.16), proliferation otherwise (R7)")
          end
        end
      end

      def size(u)
        max = config.threshold(:module_size, :max)
        flag(:module_size, u, u.line, "#{u.name} is #{u.loc} lines, over #{max}: too big to read alone (R7, Summary)") if u.loc > max
      end

      # Reported against the unit's own layer: Tukey's outer fence over the port counts of the layer's
      # units that have any, so "wide" means wide for this app, and a floor keeps a small app quiet.
      def surfaces
        counted = units.reject { _1.template? || _1.script? || composition?(_1) || model.framework_subclass?(_1) || calibration?(_1) }
                       .map { [_1, ports(_1)] }.select { _2.positive? }
        floor = config.threshold(:public_surface, :floor)
        k = config.threshold(:public_surface, :k)
        counted.group_by { _1[0].layer }.each do |layer, group|
          q1, q3 = quartiles(group.map(&:last))
          fence = q3 + k * (q3 - q1)
          limit = [floor, fence].max
          where = layer ? "the #{layer.name} layer's" : "the app's"
          group.each do |u, n|
            next unless n > limit
            flag(:public_surface, u, u.line, "#{u.name} exposes #{n} public ports, above #{number(limit)} (#{where} Q3 #{number(q3, 1)} + #{number(k, 1)} × IQR #{number(q3 - q1, 1)} = #{number(fence, 1)}; floor #{number(floor)}): " \
                                            "wide for this app; is it one learnable concept (R6), or a little ball of mud that leaked past its boundary (R7, §2.3.4)?")
          end
        end
      end

      # One per public method, except a method whose body only dispatches on the shape of a parameter
      # (`case change in { stock: } ... in { amount: }`), which is one port per pattern.
      def ports(u)
        public = u.public_methods_list.reject { _1.name == :initialize || model.paradigm_messages.include?(_1.name) }.uniq(&:name)
        public.sum do |m|
          body = m.simple_body
          dispatch = body.is_a?(Prism::CaseMatchNode) && body.predicate.is_a?(Prism::LocalVariableReadNode) && m.params.include?(body.predicate.name)
          dispatch ? body.conditions.size : 1
        end
      end

      # A table of the store's values rather than an abstraction with ports: every public method only
      # returns a literal, a constant, or a value picked from a literal table by its key argument.
      def calibration?(u)
        public = u.public_methods_list.reject { _1.name == :initialize }
        !public.empty? && public.all? { literal_value?(_1.simple_body) || literal_pick?(_1.simple_body) }
      end

      def quartiles(values)
        sorted = values.sort
        at = ->(q) { pos = q * (sorted.size - 1); lo = sorted[pos.floor]; lo + (sorted[pos.ceil] - lo) * (pos - pos.floor) }
        [at.(0.25), at.(0.75)]
      end

      def number(x, digits = nil) = digits ? format("%.#{digits}f", x) : (x == x.to_i ? x.to_i.to_s : format("%.1f", x))

      def average
        sized = model.ruby_units.reject(&:script?)
        return if sized.size < 5
        avg = sized.sum(&:loc) / sized.size.to_f
        min = config.threshold(:module_avg, :min_avg)
        return unless avg < min
        u = sized.min_by(&:loc)
        flag(:module_avg, u, u.line, "units average #{avg.round} lines (under #{min}): probably more abstractions than needed (R7, Summary); a one-rule domain class is deliberately small, so read this with the design")
      end
    end
  end
end
