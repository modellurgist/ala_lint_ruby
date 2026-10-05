module AlaLint
  module Rules
    # R6 as far as a tool can see it: meaningless names, role names (Service, Manager, Helper),
    # primitive wrappers, the tramp-parameter "should", and a UI component doing I/O.
    class Naming < Base
      MEANINGLESS = /\A(f\d*|foo|bar|baz|tmp|temp|data|stuff|thing|things|obj|val|var|x|y|z|a|b|c|do_it|do_stuff|handle_stuff|process\d+|handle\d+|run\d+|helper|util|misc)[?!=]?\z/
      ROLE_NAMES = /(Service|Manager|Helper|Handler|Utils?|Processor)\z/
      OPERATORS = %i[+ - * / % ** == != < > <= >= << & | ^ []].freeze
      STORE_CALLS = %i[find find_by where all first last create create! save save! update update! destroy destroy! perform_later perform_now deliver_later deliver_now].freeze

      def check
        units.each do |u|
          next if u.template?
          names(u)
          wrappers(u)
          tramps(u)
        end
        ui_io
      end

      private

      def names(u)
        if !u.script? && short(u.name).match?(ROLE_NAMES) && !rails_role?(u)
          flag(:r6, u, u.line, "#{u.name} is named for its role in a decomposition, not a concept (R6); what does it know about?")
        end
        u.methods.each do |m|
          next unless m.name.to_s.match?(MEANINGLESS)
          flag(:r6, u, m.line, "#{u.name}##{m.name}: a name that teaches nothing (R6)")
        end
      end

      def rails_role?(u)
        file = model.relative(u.file)
        (short(u.name).end_with?("Helper") && file.start_with?("app/helpers/")) || model.framework_subclass?(u)
      end

      # A public method whose body is one operator over its own parameters renames a primitive. A
      # predicate, and a method whose receiver is its own configured field, are concepts and spared.
      def wrappers(u)
        u.methods.select { _1.visibility == :public && !_1.name.to_s.end_with?("?") }.each do |m|
          body = m.simple_body
          next unless body.is_a?(Prism::CallNode) && OPERATORS.include?(body.name) && body.receiver.is_a?(Prism::LocalVariableReadNode)
          arg = body.arguments&.arguments&.first
          next unless arg.is_a?(Prism::LocalVariableReadNode) || arg.is_a?(Prism::IntegerNode)
          flag(:r6, u, m.line, "#{u.name}##{m.name} wraps the primitive #{body.name}: not an abstraction (R6, §1.6.3); inline it")
        end
      end

      # A parameter the method never reads, only passes bare to another unit's method that passes it
      # on again: two hops of carrying (§3.11.1). One hop is ordinary use of a lower abstraction.
      def tramps(u)
        return if composition?(u)
        u.methods.select { _1.visibility == :public && !_1.name.to_s.match?(/\A(initialize|perform|call)\z/) }.each do |m|
          m.params.each do |p|
            reads = m.reads[p]
            carries = m.calls.select { |c| c.resolved && c.resolved != u.name && c.arg_shapes.any? { _1 == [:local, p] } }
            next unless reads == carries.size && !carries.empty?
            onward = carries.any? do |c|
              target = model.unit(c.resolved)
              callee = target&.methods&.find { _1.name == c.name }
              next false unless callee
              idx = c.arg_shapes.index([:local, p])
              param = callee.params[idx]
              param && callee.reads[param] == callee.calls.count { |cc| cc.resolved && cc.arg_shapes.include?([:local, param]) } && callee.reads[param] > 0
            end
            next unless onward
            flag(:tramp, u, m.line, "#{u.name}##{m.name} never reads #{p}, only carries it to #{carries.first.resolved}, which carries it further: a tramp parameter (R6 should, §3.11.1)")
          end
        end
      end

      def ui_io
        model.templates.each do |u|
          next unless below?(u)
          u.calls.each do |c|
            store = (c.receiver_kind == :const && c.resolved && model.record?(model.unit(c.resolved))) || (c.receiver_kind == :const && STORE_CALLS.include?(c.name) && c.resolved)
            next unless store
            flag(:ui_io, u, c.line, "#{u.name} reaches #{c.receiver_name}.#{c.name}: a UI component below the composition doing I/O bundles a data source into a UI abstraction (R6, §5.2.2)")
          end
        end
      end
    end
  end
end
