module AlaLint
  module Rules
    # R1 on every edge kind the OO checklist lists (call, new, superclass, mixin, constant, render,
    # helper), layer validity, the unassigned worklist, abstraction height, and self-subscription.
    class Coupling < Base
      SUBSCRIBE_CALLS = %i[subscribe turbo_stream_from broadcast_replace_to broadcast_append_to broadcast_remove_to broadcast_action_to broadcast_render_to broadcast_update_to broadcast_prepend_to].freeze
      EDGE_WORDS = { call: "calls", new: "instantiates", superclass: "subclasses", include: "includes", extend: "extends", prepend: "prepends",
                     const: "references", render: "renders", helper: "calls helper" }.freeze

      def check
        layered? ? altitude : cycles
        height
        subscribe
      end

      private

      def altitude
        model.layers.errors.each { |unit, tag| flag(:layer, unit, unit.line, "@ala_layer #{tag} names no declared layer (#{model.layers.names.join(', ')})") }
        units.each { flag(:unassigned, _1, _1.line, "#{_1.name} matches no layer; R1 altitude, R3, R10 and R11 skip it") if _1.layer.nil? }
        model.edges.each do |from, to, ref|
          next if from.layer.nil? || to.layer.nil?
          next if ref.kind == :superclass && model.framework_base?(to)
          verb = EDGE_WORDS[ref.kind]
          if from.layer.index > to.layer.index
            flag(:r1, from, ref.line, "#{from.name}#{method_name(ref.method)} #{verb} #{to.name} (#{layer_name(to)}), which flows UP from #{layer_name(from)}: a lower abstraction naming a higher one (R1, §2.1.3)")
          elsif from.layer.index == to.layer.index && from.layer.peer_forbidden?
            hint = ref.kind == :superclass ? "a superclass in your own layer is an inheritance edge; compose instead (§2.1.3)" :
                   ref.kind == :new ? "a peer created with new is the §7.5 defect; move the new up" :
                   ref.kind == :render ? "a UI abstraction rendering a peer component; let the page place both" :
                   "the layer above should wire them (§2.2)"
            flag(:r1, from, ref.line, "#{from.name}#{method_name(ref.method)} #{verb} #{to.name}: cross-peer edge inside #{layer_name(from)}; #{hint}")
          elsif ref.callback
            flag(:r1, from, ref.line, "#{from.name} reaches #{to.name} from a model callback: a lower record deciding what happens next (R1, §4.4.2)")
          elsif ref.kind == :superclass && !composition?(from)
            flag(:r1, from, ref.line, "#{from.name} subclasses #{to.name}: a subclass of your own class breaks the lower abstraction (R1, §2.1.3); compose or delegate (§7.16)")
          end
        end
      end

      def cycles
        graph = Hash.new { |h, k| h[k] = Set.new }
        model.edges.each { |from, to, _| graph[from.name] << to.name }
        seen = {}
        units.each do |u|
          path = find_cycle(graph, u.name, [], seen)
          next unless path
          flag(:r1, u, u.line, "dependency cycle: #{path.join(' → ')} (R1; without a layer map only cycles are visible)")
        end
      end

      def find_cycle(graph, node, stack, seen)
        return nil if seen[node] == :done
        return stack.drop_while { _1 != node } + [node] if stack.include?(node)
        seen[node] = :active
        graph[node].each do |nxt|
          found = find_cycle(graph, nxt, stack + [node], seen)
          return found if found
        end
        seen[node] = :done
        nil
      end

      # Longest chain of hops between abstractions: calls within one unit and within the composition
      # count nothing; only drops between abstractions below the top add depth.
      def height
        graph = Hash.new { |h, k| h[k] = Set.new }
        model.edges.each { |from, to, _| graph[from.name] << to.name unless composition?(from) && composition?(to) }
        memo = {}
        depth = ->(n, stack) do
          return 0 if stack.include?(n)
          memo[n] ||= (graph[n].map { depth.(_1, stack + [n]) }.max || -1) + 1
        end
        h = units.map { depth.(_1.name, []) }.max || 0
        @height = h
        max = config.threshold(:height, :max)
        deepest = units.max_by { depth.(_1.name, []) }
        flag(:height, deepest, deepest.line, "abstraction height #{h} exceeds #{max} from #{deepest.name}: a long chain of hops is helper proliferation (R7)") if h > max && deepest
      end

      def subscribe
        units.each do |u|
          next unless below?(u) && !bottom?(u)
          u.calls.each do |c|
            next unless SUBSCRIBE_CALLS.include?(c.name)
            first = c.args.first
            fixed = first.is_a?(Prism::StringNode) || first.is_a?(Prism::ConstantReadNode) || first.is_a?(Prism::ConstantPathNode) || first.is_a?(Prism::SymbolNode)
            next unless fixed
            flag(:subscribe, u, c.line, "#{u.name}#{method_name(c.method)} #{c.name}s a topic it fixes: a receiver choosing its own sender (§4.4.2); let the composition pass the stream in")
          end
        end
      end
    end
  end
end
