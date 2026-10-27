module AlaLint
  module Rules
    # R11: a composition layer holds instances, configuration and wiring. In its Ruby: branches
    # (routing an outcome to a response is exempt, and so is a wiring table: `case [part, output]`
    # in `wire`), arithmetic, iteration, and handled data (one lower call's result passed into
    # another; a part's call fed to `run`, including a pull passed straight in, is a wire). In its templates: branches, comparisons, arithmetic,
    # loops, and calls into units below the composition. In both, a template, method or class chosen
    # by a name built at run time. Plus the two never-scored shares.
    class Composition < Base
      WIRING = %i[wire_to wire_in on input_port push send_event request call new tap then freeze run out collect].freeze
      EDGE = %i[params expect permit require to_i to_s to_sym fetch dig [] presence].freeze
      EDGE_RECEIVERS = %w[session params flash cookies request response helpers].freeze
      COMPARISONS = %i[== != < > <= >= <=> include? === =~].freeze
      NAME_ARGUMENTS = %i[send public_send __send__ method const_get].freeze
      NAME_RECEIVERS = %i[constantize safe_constantize].freeze
      TEMPLATE_KEYS = %w[partial template].freeze
      RENDER_KEYS = %w[partial template layout action file spacer_template].freeze
      NAME_BUILDERS = %i[+ % join format sprintf to_s to_sym intern].freeze

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
          run_time_names(u, m, m.calls)
        end
        constants(u)
      end

      # Logic outside every method sits in a lambda a constant holds (`TIER = ->(s) { s > 1 ? … }`): the
      # same branch as in a method, attributed to the constant so a reader finds it.
      def constants(u)
        u.branches.each do |node, _|
          next if routing?(node)
          name = holder(u, node) or next
          kind = node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode) ? "compound condition" : node.class.name.split("::").last.delete_suffix("Node").downcase
          logic(u, name, node.location.start_line, "#{u.name}::#{name} branches (#{kind}) in a lambda the constant holds: logic in the composition (R11, §3.5); fine as an application-specific pure function handed to an instance (§6.28.1), a rule otherwise belongs in a configured instance")
        end
        u.arith.each { |node, _| name = holder(u, node) and logic(u, name, node.location.start_line, "#{u.name}::#{name} computes (#{node.name}) in a lambda the constant holds: arithmetic in the composition (R11)") }
        u.loops.each { |node, _| name = holder(u, node) and logic(u, name, node.location.start_line, "#{u.name}::#{name} iterates (#{node.name}) in a lambda the constant holds (R11, §1.6.3); a generic abstraction iterates") }
      end

      def holder(u, node)
        u.constant_values.find { |_, v| v.location.start_offset <= node.location.start_offset && node.location.end_offset <= v.location.end_offset }&.first
      end

      def lambda_constants(u)
        u.constant_values.count { |_, v| holds_lambda?(v) }
      end

      def holds_lambda?(node)
        node.is_a?(Prism::LambdaNode) || node.compact_child_nodes.any? { holds_lambda?(_1) }
      end

      # A branch whose every arm only renders, redirects, or sets a view field is routing an outcome.
      def routing?(node)
        arms = case node
               when Prism::IfNode, Prism::UnlessNode then [node.statements, node.respond_to?(:subsequent) ? node.subsequent : node.consequent]
               when Prism::CaseNode, Prism::CaseMatchNode then node.conditions.map(&:statements) + [node.else_clause&.statements]
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
        when Prism::CallNode then template_append?(s) || (ROUTING.include?(s.name) && s.receiver.nil?) || s.name.to_s.match?(/_(path|url)\z/) || (s.receiver.nil? && s.name == :screen)
        when Prism::ReturnNode then s.arguments.nil? || s.arguments.arguments.all? { routing_statement?(_1) }
        when Prism::InstanceVariableWriteNode then landing_value?(s.value)
        when Prism::NilNode then true
        else false
        end
      end

      # In a compiled template an arm appends to `_erbout`: markup, or a rendered view, picks a view; a value doesn't.
      def template_append?(s)
        return false unless s.name == :<< && s.receiver.is_a?(Prism::LocalVariableReadNode) && s.receiver.name == :_erbout
        arg = s.arguments&.arguments&.first
        arg = arg.body.body.first while arg.is_a?(Prism::ParenthesesNode) && arg.body.respond_to?(:body) && arg.body.body.size == 1
        arg = arg.receiver while arg.is_a?(Prism::CallNode) && %i[to_s freeze].include?(arg.name) && arg.receiver
        arg = arg.body.body.first while arg.is_a?(Prism::ParenthesesNode) && arg.body.respond_to?(:body) && arg.body.body.size == 1
        arg.is_a?(Prism::StringNode) || (arg.is_a?(Prism::CallNode) && arg.receiver.nil? && ROUTING.include?(arg.name))
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
          next if c.instance_variable_get(:@in_block) || c.instance_variable_get(:@wired_arg)
          next if c.receiver_kind == :call && EDGE_RECEIVERS.include?(c.receiver_name)
          next if config.threshold(:r11, :calls) == :wired_only && %i[ivar local].include?(c.receiver_kind) && !u.wired?(c.receiver_name)
          c.arg_shapes.each do |shape, value|
            if shape == :local && handed.include?(value)
              logic(u, m, c.line, "#{u.name}##{m.name} hands #{value} (one abstraction's result) to #{c.name}: the composition handling data between abstractions (R11, §1.6.3); wire the two ports")
            elsif shape == :call && handed_call?(value)
              logic(u, m, c.line, "#{u.name}##{m.name} passes #{value.slice[0, 40]} straight into #{c.name}: the composition handling data between abstractions (R11, §1.6.3)")
            end
          end
        end
      end

      # A result passed straight on is handled data; a no-argument read of a name on a constant or a
      # local (`Store::RATES`, `dom.summary_id`) is configuration being passed, which is wiring.
      def handed_call?(node)
        return false if node.name == :new || EDGE.include?(node.name) || WIRING.include?(node.name) || node.name.to_s.match?(/_(path|url)\z/)
        return false if node.receiver.nil? || node.receiver.is_a?(Prism::CallNode) && EDGE.include?(node.receiver.name)
        recv = node.receiver
        return true if recv.is_a?(Prism::InstanceVariableReadNode)
        (recv.is_a?(Prism::LocalVariableReadNode) || recv.is_a?(Prism::ConstantReadNode) || recv.is_a?(Prism::ConstantPathNode)) && !node.arguments.nil?
      end

      # Choosing what runs by a name built at run time is the branch with its arms out of sight. A name
      # written in the code, picked from a literal table, or passed in as one by every caller is not.
      def run_time_names(u, m, calls)
        calls.each do |c|
          name = run_time_name(c, u, m)
          next unless name
          who = m ? "#{u.name}##{m.name}" : u.name
          logic(u, m, c.line, "#{who} chooses what runs by a name built at run time (#{c.name} #{name.slice.lines.first.strip[0, 50]}): a branch with its arms out of sight (R11, §3.5); " \
                              "name each choice instead: a literal table, or a case whose arms only render, is routing")
        end
      end

      def run_time_name(c, u, m)
        if NAME_ARGUMENTS.include?(c.name)
          arg = c.args.first
          arg unless arg.nil? || named?(arg, u, m)
        elsif NAME_RECEIVERS.include?(c.name)
          recv = c.node.receiver
          recv unless recv.nil? || named?(recv, u, m)
        else
          render = c.name == :render && c.receiver_kind == :none
          first = c.args.first
          return first if render && first && !first.is_a?(Prism::KeywordHashNode) && built?(first, u, m)
          # after a positional name, `render "x", action: ...` passes locals, not options
          keys = !render ? TEMPLATE_KEYS : first.is_a?(Prism::KeywordHashNode) ? RENDER_KEYS : []
          c.args.grep(Prism::KeywordHashNode).flat_map(&:elements).find do |el|
            el.is_a?(Prism::AssocNode) && keys.include?(el.key.respond_to?(:unescaped) && el.key.unescaped) && !named?(el.value, u, m)
          end&.value
        end
      end

      def named?(node, u, m, depth = 0)
        case node
        when *LITERALS then true
        when Prism::LocalVariableReadNode
          return named_parameter?(node.name, u, m, depth) if m&.params&.include?(node.name)
          values = u.assigned_values(node.name.to_s, m&.name)
          !values.empty? && values.all? { named?(_1, u, m, depth) }
        when Prism::InstanceVariableReadNode
          values = u.assigned_values(node.name.to_s, nil)
          !values.empty? && values.all? { named?(_1, u, m, depth) }
        else configuration_read?(node) || (literal_pick?(node) && name_table?(table(node.receiver, u)))
        end
      end

      # A name read from the app's configuration is fixed when the app boots, not chosen per request.
      def configuration_read?(node)
        chain = []
        while node.is_a?(Prism::CallNode)
          chain << node.name
          node = node.receiver
        end
        return false unless node.is_a?(Prism::ConstantReadNode)
        node.name == :ENV || (node.name == :Rails && chain.intersect?(%i[configuration config]))
      end

      # Only a name that some code assembles counts for `render x`, which also renders objects.
      def built?(node, u, m)
        case node
        when Prism::InterpolatedStringNode, Prism::InterpolatedSymbolNode then node.parts.any? { !_1.is_a?(Prism::StringNode) }
        when Prism::CallNode then NAME_BUILDERS.include?(node.name) && [node.receiver, *node.arguments&.arguments].compact.any? { !named?(_1, u, m) }
        when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode
          u.assigned_values(node.name.to_s, node.is_a?(Prism::LocalVariableReadNode) ? m&.name : nil).any? { built?(_1, u, m) }
        else false
        end
      end

      # A parameter is a name when every call of its method passes one; with no caller in sight it is a run-time value.
      def named_parameter?(param, u, m, depth)
        return false if depth > 2
        index = m.params.index(param)
        sites = units.flat_map { |x| x.calls.select { |c| c.name == m.name && (c.resolved == u.name || (x == u && %i[none self].include?(c.receiver_kind))) }.map { [x, _1] } }
        !sites.empty? && sites.all? do |x, c|
          arg = keyword_arg(c.args, param.to_s) || c.args[index]
          arg && named?(arg, x, x.methods.find { _1.name == c.method }, depth + 1)
        end
      end

      def table(node, u)
        node = node.receiver while node.is_a?(Prism::CallNode) && node.name == :freeze
        return node unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
        name = node.name.to_s
        value = u.constant_values[name] || units.find { _1.constant_values.key?(name) }&.constant_values&.[](name)
        value = value.receiver while value.is_a?(Prism::CallNode) && value.name == :freeze
        value
      end

      def name_table?(t)
        values = case t
                 when Prism::HashNode then t.elements.map { _1.is_a?(Prism::AssocNode) ? _1.value : nil }
                 when Prism::ArrayNode then t.elements
                 else return false
                 end
        values.all? { |v| [Prism::StringNode, Prism::SymbolNode, Prism::ConstantReadNode, Prism::ConstantPathNode, Prism::LambdaNode].any? { v.is_a?(_1) } }
      end

      def template(u)
        u.branches.each do |node, _|
          next if routing?(node)
          kind = node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode) ? "&&/||" : node.class.name.split("::").last.delete_suffix("Node").downcase
          logic(u, nil, node.location.start_line - 1, "#{u.name} branches (#{kind}) in an application template: template logic (R11); a generic component takes the value and the name")
        end
        u.loops.each { |node, _| logic(u, nil, node.location.start_line - 1, "#{u.name} iterates (#{node.name}) in an application template (R11); let a collection component or `render collection:` iterate") }
        u.arith.each { |node, _| logic(u, nil, node.location.start_line - 1, "#{u.name} computes (#{node.name}) in an application template (R11)") }
        run_time_names(u, nil, u.calls)
        u.calls.each do |c|
          if COMPARISONS.include?(c.name) && c.receiver_kind != :none
            logic(u, nil, c.line, "#{u.name} compares (#{c.name}) in an application template (R11); let the row carry the boolean")
          elsif c.receiver_kind == :const && c.resolved && (t = model.unit(c.resolved)) && below?(t) && c.name != :new
            logic(u, nil, c.line, "#{u.name} calls #{c.receiver_name}.#{c.name}, a unit below the composition, from a template (R11); pass the value in from the screen")
          end
        end
      end

      def logic(u, m, line, message)
        @logic[u.name] << (m.respond_to?(:name) ? m.name : (m || :template))
        flag(:r11, u, line, message)
      end

      def shares
        comp = units.select { composition?(_1) }
        comp_functions = comp.sum { _1.template? ? 1 : _1.methods.size + lambda_constants(_1) }
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
