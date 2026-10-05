module AlaLint
  module Rules
    # R7's advisories: dead private methods, pass-throughs, unit size, the average size, and the
    # public surface a little ball of mud is allowed before it has leaked.
    class Minimality < Base
      def check
        units.each do |u|
          next if u.template?
          dead_privates(u)
          passthroughs(u)
          size(u)
          surface(u)
        end
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

      def surface(u)
        return if composition?(u) || u.script? || model.framework_subclass?(u)
        public = u.methods.select { _1.visibility == :public && !_1.singleton && _1.name != :initialize }.map(&:name).uniq
        max = config.threshold(:public_surface, :max)
        return unless public.size > max
        flag(:public_surface, u, u.line, "#{u.name} exposes #{public.size} public methods (max #{max}): a wide main interface means the little ball of mud has leaked past its boundary (R7, R9 §2.3.4)")
      end

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
