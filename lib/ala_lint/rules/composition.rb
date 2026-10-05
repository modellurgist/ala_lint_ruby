module AlaLint
  module Rules
    # R11: a composition layer holds instances, configuration and wiring. In its Ruby: branches
    # (routing an outcome to a response is exempt), arithmetic, iteration, and handled data (one
    # lower call's result passed into another). In its templates: branches, comparisons, arithmetic,
    # loops, and calls into units below the composition. Plus the two never-scored shares.
    class Composition < Base
      ROUTING = %i[redirect_to render head respond_to format turbo_stream redirect_back_or_to].freeze
      WIRING = %i[wire_to wire_in on input_port push send_event request call new tap then freeze].freeze
      EDGE = %i[params expect permit require to_i to_s to_sym fetch dig [] presence].freeze
      EDGE_RECEIVERS = %w[session params flash cookies request response helpers].freeze
      COMPARISONS = %i[== != < > <= >= <=> include? === =~].freeze

      def check
        return unless layered?
        @logic = Hash.new { |h, k| h[k] = Set.new }
        units.select { composition?(_1) }.each { _1.template? ? template(_1) : ruby(_1) }
        shares
      end

      private

      def ruby(u)
        u.methods.each do |m|
          next if m.name == :initialize && false
          m.branches.each do |node, in_block|
            next if routing?(node)
            kind = node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode) ? "compound condition" : node.class.name.split("::").last.delete_suffix("Node").downcase
            where = in_block ? " (inside a wiring block)" : ""
            logic(u, m, node.location.start_line, "#{u.name}##{m.name} branches (#{kind})#{where}: logic in the composition (R11, §3.5); a guard goes into the connection, a rule into a configured instance, history into a state machine, an outcome into two ports")
          end
          m.arith.each { |node, _| logic(u, m, node.location.start_line, "#{u.name}##{m.name} computes (#{node.name}): arithmetic in the composition (R11)") }
          m.loops.each { |node, _| logic(u, m, node.location.start_line, "#{u.name}##{m.name} iterates (#{node.name}): Spray's \"for loop\" in the application (R11, §1.6.3); a generic abstraction iterates") }
          handoffs(u, m)
        end
      end

      # A branch whose every arm only renders, redirects, or sets a view field is routing an outcome.
      def routing?(node)
        arms = case node
               when Prism::IfNode, Prism::UnlessNode then [node.statements, node.respond_to?(:subsequent) ? node.subsequent : node.consequent]
               when Prism::CaseNode then node.conditions.map(&:statements) + [node.else_clause&.statements]
               else return false
               end
        arms = arms.flat_map { arm_statements(_1) }
        !arms.empty? && arms.all? { routing_statement?(_1) }
      end

      def arm_statements(arm)
        case arm
        when nil then []
        when Prism::StatementsNode then arm.body
        when Prism::ElseNode then arm_statements(arm.statements)
        when Prism::IfNode, Prism::UnlessNode then routing?(arm) ? [] : [arm]
        else [arm]
        end
      end

      def routing_statement?(s)
        case s
        when Prism::CallNode then (ROUTING.include?(s.name) && s.receiver.nil?) || s.name.to_s.match?(/_(path|url)\z/) || (s.receiver.nil? && s.name == :screen)
        when Prism::ReturnNode then s.arguments.nil? || s.arguments.arguments.all? { routing_statement?(_1) }
        when Prism::InstanceVariableWriteNode then landing_value?(s.value)
        when Prism::NilNode then true
        else false
        end
      end

      # A view field set to a landed value, a constant, a parameter or a literal: handing the view
      # what to show, not computing.
      def landing_value?(v)
        (v.is_a?(Prism::CallNode) && v.arguments.nil?) || v.is_a?(Prism::ConstantPathNode) || v.is_a?(Prism::ConstantReadNode) ||
          v.is_a?(Prism::LocalVariableReadNode) || v.is_a?(Prism::StringNode) || v.is_a?(Prism::SymbolNode)
      end

      # One lower abstraction's result bound to a local and passed to another, or passed straight in
      # as an argument. Building configuration (`new`), wiring calls, param decoding and rendering
      # the landed values are the framework's and the composition's own business.
      def handoffs(u, m)
        handed = m.handoffs.map(&:first).to_set
        m.calls.each do |c|
          next if WIRING.include?(c.name) || ROUTING.include?(c.name) || c.name.to_s.match?(/_(path|url)\z/) || c.receiver_kind == :none && c.name == :screen
          next if c.instance_variable_get(:@in_block)
          next if c.receiver_kind == :call && EDGE_RECEIVERS.include?(c.receiver_name)
          c.arg_shapes.each do |shape, value|
            if shape == :local && handed.include?(value)
              logic(u, m, c.line, "#{u.name}##{m.name} hands #{value} (one abstraction's result) to #{c.name}: the composition handling data between abstractions (R11, §1.6.3); wire the two ports")
            elsif shape == :call && handed_call?(value)
              logic(u, m, c.line, "#{u.name}##{m.name} passes #{value.slice[0, 40]} straight into #{c.name}: the composition handling data between abstractions (R11, §1.6.3)")
            end
          end
        end
      end

      def handed_call?(node)
        return false if node.name == :new || EDGE.include?(node.name) || WIRING.include?(node.name) || node.name.to_s.match?(/_(path|url)\z/)
        return false if node.receiver.nil? || node.receiver.is_a?(Prism::CallNode) && EDGE.include?(node.receiver.name)
        recv = node.receiver
        recv.is_a?(Prism::InstanceVariableReadNode) || recv.is_a?(Prism::LocalVariableReadNode) || recv.is_a?(Prism::ConstantReadNode) || recv.is_a?(Prism::ConstantPathNode)
      end

      def template(u)
        u.branches.each do |node, _|
          kind = node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode) ? "&&/||" : node.class.name.split("::").last.delete_suffix("Node").downcase
          logic(u, nil, node.location.start_line - 1, "#{u.name} branches (#{kind}) in an application template: template logic (R11); a generic component takes the value and the name")
        end
        u.loops.each { |node, _| logic(u, nil, node.location.start_line - 1, "#{u.name} iterates (#{node.name}) in an application template (R11); let a collection component or `render collection:` iterate") }
        u.arith.each { |node, _| logic(u, nil, node.location.start_line - 1, "#{u.name} computes (#{node.name}) in an application template (R11)") }
        u.calls.each do |c|
          if COMPARISONS.include?(c.name) && c.receiver_kind != :none
            logic(u, nil, c.line, "#{u.name} compares (#{c.name}) in an application template (R11); let the row carry the boolean")
          elsif c.receiver_kind == :const && c.resolved && (t = model.unit(c.resolved)) && below?(t) && c.name != :new
            logic(u, nil, c.line, "#{u.name} calls #{c.receiver_name}.#{c.name}, a unit below the composition, from a template (R11); pass the value in from the screen")
          end
        end
      end

      def logic(u, m, line, message)
        @logic[u.name] << (m ? m.name : :template)
        flag(:r11, u, line, message)
      end

      def shares
        comp = units.select { composition?(_1) }
        comp_functions = comp.sum { _1.template? ? 1 : _1.methods.size }
        total = model.functions
        return if total.zero?
        share = comp_functions / total.to_f
        max = config.threshold(:app_share, :max)
        top = comp.first
        if share > max && top
          flag(:app_share, top, top.line, "the composition layers hold #{(share * 100).round}% of all functions (max #{(max * 100).round}%): Spray's application is 3–10% of the code (§2.4); a ratio, not a defect")
        end
        with_logic = @logic.values.sum(&:size)
        return if comp_functions.zero? || with_logic.zero?
        flag(:r11_share, top, top.line, "#{with_logic} of #{comp_functions} composition functions hold logic (#{(with_logic * 100.0 / comp_functions).round}%): the share R11's per-finding count can't show")
      end
    end
  end
end
