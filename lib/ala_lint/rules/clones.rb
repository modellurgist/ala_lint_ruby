module AlaLint
  module Rules
    # R7 (checklist reading): the same logic written in two methods. Each method body becomes a
    # sequence of node tokens in which local names, parameters, fields and literal values are
    # placeholders and call, constant and symbol names stay (they carry the meaning). Every pair of
    # methods is aligned locally, so a copied run inside a larger method is found as well as a whole
    # copy, and an edited copy still matches above the similarity floor. Methods linked by matches are
    # reported once, as a group: `clone` across units, `clone_inside` within one.
    class Clones < Base
      MATCH = 2
      MISMATCH = -3
      GAP = -2
      EMPTY = [0, 0, 0, 0].freeze
      WRAPPERS = [Prism::StatementsNode, Prism::ArgumentsNode, Prism::ParenthesesNode].freeze
      LITERALS = [Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode, Prism::ImaginaryNode, Prism::StringNode,
                  Prism::XStringNode, Prism::RegularExpressionNode].freeze
      PLACEHOLDER = /LocalVariable|Parameter|InstanceVariable|NumberedReference|ItLocalVariable/

      Fragment = Struct.new(:unit, :method, :tokens, :lines, keyword_init: true)
      Match = Struct.new(:a, :b, :matched, :a_from, :a_to, :b_from, :b_to, keyword_init: true)

      def check
        fragments = units.reject { _1.template? || _1.script? }.flat_map { |u| u.methods.reject { placing?(u, _1) }.map { fragment(u, _1) } }
        fragments.select! { _1.tokens.size >= min_nodes }
        matches = candidate_pairs(fragments).filter_map { |a, b| clone_of(a, b) }
        groups(matches).each { report(_1) }
      end

      private

      def min_nodes = config.threshold(:clone, :min_nodes)
      def min_similarity = config.threshold(:clone, :min_similarity)

      # A composition's constructor places and configures its parts, and `parts` lists them: two pages
      # placing the same parts read alike because they are wiring, which R11 already reads.
      def placing?(unit, method) = composition?(unit) && %i[initialize parts].include?(method.name)

      def fragment(unit, method)
        tokens = []
        lines = []
        skip = method.wiring_tables.to_set.compare_by_identity
        tokenize(method.body, tokens, lines, skip)
        Fragment.new(unit: unit, method: method, tokens: tokens, lines: lines)
      end

      # A wiring table's arms are wires and a render or redirect routes an outcome: both are alike by
      # design (the Rails form is the framework's), so neither counts; the rest of the body does.
      def tokenize(node, tokens, lines, skip)
        return unless node.is_a?(Prism::Node) && !skip.include?(node)
        return if node.is_a?(Prism::CallNode) && node.receiver.nil? && ROUTING.include?(node.name)
        unless WRAPPERS.any? { node.is_a?(_1) }
          tokens << token(node)
          lines << node.location.start_line
        end
        return if node.is_a?(Prism::ConstantPathNode)
        node.compact_child_nodes.each { tokenize(_1, tokens, lines, skip) }
      end

      def token(node)
        case node
        when Prism::CallNode then "call #{node.name}"
        when Prism::ConstantReadNode then "const #{node.name}"
        when Prism::ConstantPathNode then "const #{node.slice}"
        when Prism::SymbolNode then "sym #{node.unescaped}"
        when *LITERALS then "literal"
        else node.class.name.delete_prefix("Prism::").sub(PLACEHOLDER, "Name")
        end
      end

      # A pair worth aligning shares a run of a few identical tokens; aligning every pair would be
      # quadratic in methods and in tokens.
      def candidate_pairs(fragments, k = 4)
        index = Hash.new { |h, key| h[key] = [] }
        fragments.each_with_index do |f, i|
          f.tokens.each_cons(k).map(&:hash).uniq.each { index[_1] << i }
        end
        pairs = Set.new
        index.each_value do |ids|
          next if ids.size > 40
          ids.combination(2) { |i, j| pairs << [i, j] unless fragments[i].method.equal?(fragments[j].method) }
        end
        pairs.map { |i, j| [fragments[i], fragments[j]] }
      end

      # Smith-Waterman over the two token sequences, carrying each cell's match count and start so
      # the best local alignment's extent needs no traceback.
      def clone_of(a, b)
        x, y = a.tokens, b.tokens
        prev = Array.new(y.size + 1, EMPTY)
        best = [0, 0, 0, 0, 0, 0]
        x.each_with_index do |xt, i|
          row = [EMPTY]
          y.each_with_index do |yt, j|
            diag, up, left = prev[j], prev[j + 1], row[j]
            same = xt == yt
            step = same ? MATCH : MISMATCH
            along = diag[0].positive? ? [diag[0] + step, diag[1] + (same ? 1 : 0), diag[2], diag[3]] : [step, same ? 1 : 0, i, j]
            cell = [along, [up[0] + GAP, *up[1..]], [left[0] + GAP, *left[1..]]].max_by(&:first)
            cell = EMPTY if cell[0] <= 0
            row << cell
            best = [cell[0], cell[1], cell[2], i, cell[3], j] if cell[0] > best[0]
          end
          prev = row
        end
        _, matched, a_from, a_to, b_from, b_to = best
        return nil if matched < min_nodes
        return nil if 2.0 * matched / ((a_to - a_from + 1) + (b_to - b_from + 1)) < min_similarity
        Match.new(a: a, b: b, matched: matched, a_from: a_from, a_to: a_to, b_from: b_from, b_to: b_to)
      end

      # Two matches are one group when they cover the same stretch of a method they share; sharing a
      # method alone would chain unrelated clones through one long method.
      def groups(matches)
        parent = {}.compare_by_identity
        root = ->(m) { (parent[m] ||= m).equal?(m) ? m : (parent[m] = root.(parent[m])) }
        stretches = matches.flat_map { |m| [[m.a, m.a_from..m.a_to, m], [m.b, m.b_from..m.b_to, m]] }
        stretches.group_by { _1[0].object_id }.each_value do |same_method|
          same_method.combination(2) { |(_, x, m), (_, y, n)| parent[root.(m)] = root.(n) if overlapping?(x, y) }
        end
        matches.group_by { root.(_1).object_id }.values.map { |ms| ms.sort_by { -_1.matched } }
      end

      def overlapping?(x, y) = [x.end, y.end].min - [x.begin, y.begin].max + 1 >= [x.size, y.size].min / 2.0

      def report(matches)
        starts = {}.compare_by_identity
        matches.each do |m|
          starts[m.a] ||= m.a.lines[m.a_from]
          starts[m.b] ||= m.b.lines[m.b_from]
        end
        members = starts.keys.sort_by { [model.relative(_1.unit.file), starts[_1]] }
        top = matches.first
        size = [top.a_to - top.a_from, top.b_to - top.b_from].max + 1
        how = top.matched == size ? "the same logic (#{top.matched} nodes)" : "nearly the same logic (#{top.matched} of #{size} nodes match)"
        names = members.map { |f| "#{label(f)} (#{model.relative(f.unit.file)}:#{starts[f]})" }
        listed = "#{names[0...-1].join(', ')} and #{names.last}"
        first = members.first
        if members.map { _1.unit.name }.uniq.size == 1
          flag(:clone_inside, first.unit, starts[first],
               "#{listed} are #{how} inside one abstraction: its interior is a little ball of mud the checklist leaves to its author (R7); a private method both call would say it once")
        else
          flag(:clone, first.unit, starts[first],
               "#{listed} are #{how}: one concept written #{members.size == 2 ? 'twice' : "#{members.size} times"} (\"no other elements should know about this one thing\", §7.25); " \
               "extract it into an abstraction #{members.size == 2 ? 'both' : 'all'} compose, configured from the composition (R7, checklist reading)")
        end
      end

      def label(f) = "#{short(f.unit.name)}#{f.method.singleton ? '.' : '#'}#{f.method.name}"
    end
  end
end
