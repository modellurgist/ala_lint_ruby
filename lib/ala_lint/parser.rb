require "prism"

module AlaLint
  # Reads one Ruby file with Prism into Source::Units. Visibility is tracked the way Ruby does it
  # (`private` as a section, `private def`, `private :a`, `class << self`), constants are kept as
  # written with their lexical nesting so Model can resolve them later.
  class Parser
    MACROS = %i[validates validate has_many has_one belongs_to has_and_belongs_to_many scope
                before_action after_action around_action skip_before_action
                after_commit after_save before_save after_create before_create after_update before_update
                after_destroy before_destroy after_initialize after_find
                include extend prepend attr_reader attr_accessor attr_writer delegate
                output input helper helper_method queue_as broadcasts_to broadcasts].freeze
    VISIBILITY = %i[private protected public module_function private_class_method].freeze

    def self.parse(file, root, source: nil)
      new(file, root, source: source).parse
    end

    def initialize(file, root, source: nil)
      @file = file
      @root = root
      @units = []
      @inherent = 0
      @source = source || File.read(file)
      @result = Prism.parse(@source)
      @comments = @result.comments
    end

    def parse
      prog = @result.value
      loose = prog.statements.body.reject { _1.is_a?(Prism::ClassNode) || _1.is_a?(Prism::ModuleNode) || defined_type?(_1) }
      walk_namespace(prog.statements.body, [], [])
      unless loose.empty?
        unit = new_unit(relative_name, :script, prog.location.start_line, prog.location.end_line, [], [])
        loose.each { visit(_1, unit, nil, [], false) }
        @units << unit
      end
      @units.each { _1.loc = loc_of(_1) }
      @units
    end

    private

    # `Money = Data.define(:cents)` and `Point = Struct.new(:x)` define a type without a class keyword.
    def defined_type?(node)
      node.is_a?(Prism::ConstantWriteNode) && node.value.is_a?(Prism::CallNode) && node.value.receiver.is_a?(Prism::ConstantReadNode) &&
        %w[Data Struct Class].include?(node.value.receiver.name.to_s) && %i[define new].include?(node.value.name)
    end

    def relative_name = @file.delete_prefix(@root).delete_prefix("/").sub(/\.rb\z/, "")

    # A class/module with members is a unit; one that only nests others (or `X = Data.define`
    # types, which are units of their own) is a namespace.
    def walk_namespace(nodes, nesting, includes)
      nodes.each do |node|
        if defined_type?(node)
          unit = new_unit((nesting + [node.name.to_s]).join("::"), :class, node.location.start_line, node.location.end_line, nesting + [node.name.to_s], [])
          unit.header_comment = header_comment(node.location.start_line)
          unit.data_type = :value
          visit(node.value, unit, nil, nesting + [node.name.to_s], false)
          @units << unit
          next
        end
        next unless node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
        name = const_name(node.constant_path)
        full = (nesting + [name]).join("::")
        body = node.body.respond_to?(:body) ? node.body.body : []
        if body.all? { _1.is_a?(Prism::ClassNode) || _1.is_a?(Prism::ModuleNode) || defined_type?(_1) }
          walk_namespace(body, nesting + [name], includes)
        else
          unit = new_unit(full, node.is_a?(Prism::ClassNode) ? :class : :module, node.location.start_line, node.location.end_line, nesting + [name], includes)
          unit.superclass = const_name(node.superclass) if node.is_a?(Prism::ClassNode) && node.superclass
          add_ref(unit, unit.superclass, :superclass, node.location.start_line, nil) if unit.superclass
          unit.header_comment = header_comment(node.location.start_line)
          unit.tag = unit.header_comment[/@ala_layer\s+:?(\w+)/, 1]
          visit_body(body, unit, nil, nesting + [name], false)
          @units << unit
        end
      end
    end

    def new_unit(name, kind, line, end_line, nesting, includes)
      Source::Unit.new(
        name: name, file: @file, line: line, end_line: end_line, kind: kind, loc: 0, includes: [], extends: [], prepends: [],
        methods: [], constants: {}, refs: [], calls: [], literals: [], strings: [], ivar_writes: [], cvars: [], gvars: [],
        header_comment: "", tag: nil, outputs: {}, inputs: {}, macros: [], symbols: [], texts: [], attr_readers: [],
        data_type: nil, branches: [], arith: [], loops: [], layer: nil, body_nodes: [], lambda_ivar_writes: [], inherent_declarations: []
      ).tap { _1.instance_variable_set(:@nesting, nesting) }
    end

    def header_comment(line)
      lines = []
      l = line - 1
      while (c = @comments.find { _1.location.start_line == l })
        lines.unshift(c.slice.sub(/\A#\s?/, ""))
        l -= 1
      end
      lines.join("\n")
    end

    # Walks a class body: a visibility section applies to the defs after it; nested classes are the
    # same unit; everything else is visited for refs, calls and literals at class level.
    def visit_body(nodes, unit, method, nesting, singleton, visibility = :public)
      nodes.each do |node|
        case node
        when Prism::CallNode
          if node.receiver.nil? && VISIBILITY.include?(node.name)
            if node.arguments.nil?
              visibility = node.name == :public ? :public : :private
              next
            end
            node.arguments.arguments.each do |arg|
              case arg
              when Prism::DefNode then visit_def(arg, unit, nesting, singleton, :private)
              when Prism::SymbolNode then unit.methods.find { _1.name == arg.unescaped.to_sym }&.visibility = :private
              else visit(arg, unit, method, nesting, singleton)
              end
            end
            next
          end
          visit(node, unit, method, nesting, singleton)
        when Prism::DefNode then visit_def(node, unit, nesting, singleton, visibility)
        when Prism::ClassNode, Prism::ModuleNode
          inner = nesting + [const_name(node.constant_path)]
          unit.constants[inner.last] = node.location.start_line
          body = node.body.respond_to?(:body) ? node.body.body : []
          visit_body(body, unit, nil, inner, false)
        when Prism::SingletonClassNode
          body = node.body.respond_to?(:body) ? node.body.body : []
          visit_body(body, unit, nil, nesting, true)
        else visit(node, unit, method, nesting, singleton)
        end
      end
    end

    def visit_def(node, unit, nesting, singleton, visibility)
      m = Source::Method.new(
        name: node.name, line: node.location.start_line, end_line: node.location.end_line, visibility: visibility,
        singleton: singleton || !node.receiver.nil?, params: [], keyword_defaults: {}, body: node.body, reads: Hash.new(0),
        calls: [], refs: [], unit: unit.name, ivar_writes: [], simple_body: nil, branches: [], arith: [], loops: [], handoffs: []
      )
      m.visibility = :public if m.singleton && visibility == :private && !@private_singleton
      if node.parameters
        p = node.parameters
        m.params = (p.requireds + p.optionals + p.posts + p.keywords).filter_map { _1.respond_to?(:name) ? _1.name : nil }
        (p.optionals + p.keywords).each { |k| m.keyword_defaults[k.name] = k.value if k.respond_to?(:value) && k.value }
        m.params << p.rest.name if p.rest.respond_to?(:name) && p.rest.name
        m.params << p.keyword_rest.name if p.keyword_rest.respond_to?(:name) && p.keyword_rest.name
      end
      previous, @literal_context = @literal_context, :default
      m.keyword_defaults.each_value { visit(_1, unit, m, nesting, singleton) }
      @literal_context = previous
      unit.methods << m
      body = node.body.respond_to?(:body) ? node.body.body : (node.body ? [node.body] : [])
      m.simple_body = body.size == 1 ? body.first : nil
      body.each { visit(_1, unit, m, nesting, singleton) }
    end

    # One generic walk collecting what every rule later reads. `in_block` marks code that runs later
    # than the method it sits in (a lambda or block body), which R4 and R11 treat differently.
    def visit(node, unit, method, nesting, singleton, in_block = false)
      return unless node.is_a?(Prism::Node)
      line = node.location.start_line
      case node
      when Prism::DefNode
        visit_def(node, unit, nesting, singleton, :public)
        return
      when Prism::ClassNode, Prism::ModuleNode
        visit_body([node], unit, method, nesting, singleton)
        return
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        add_ref(unit, const_name(node), :const, line, method)
        return
      when Prism::HashNode, Prism::KeywordHashNode
        visit_hash(node, unit, method, nesting, singleton, in_block)
        return
      when Prism::ConstantWriteNode
        unit.constants[node.name.to_s] = line
        visit_declared_value(node.name.to_s, node.value, unit, method, nesting, singleton, in_block, line)
        return
      when Prism::CallNode
        visit_call(node, unit, method, nesting, singleton, in_block)
        return
      when Prism::IntegerNode, Prism::FloatNode
        unit.literals << Source::Literal.new(value: node.value, line: line, method: method&.name, context: @literal_context)
        return
      when Prism::StringNode
        add_string(unit, node.unescaped, line, method, false)
        return
      when Prism::InterpolatedStringNode
        text = node.parts.map { _1.is_a?(Prism::StringNode) ? _1.unescaped : "\#{}" }.join
        add_string(unit, text, line, method, true)
        node.parts.each { |p| visit(p.respond_to?(:statements) ? p.statements : p, unit, method, nesting, singleton, in_block) }
        return
      when Prism::SymbolNode
        unit.symbols << node.unescaped
        return
      when Prism::InstanceVariableWriteNode, Prism::InstanceVariableOrWriteNode, Prism::InstanceVariableOperatorWriteNode
        w = Source::IvarWrite.new(name: node.name, line: line, method: method&.name, in_block: in_block,
                                  operator: node.respond_to?(:binary_operator) ? node.binary_operator : (node.is_a?(Prism::InstanceVariableOrWriteNode) ? :"||" : nil),
                                  value_kind: value_kind(node.value))
        (method ? method.ivar_writes : unit.ivar_writes) << w
        unit.ivar_writes << w if method
        visit_declared_value(node.name.to_s, node.value, unit, method, nesting, singleton, in_block, line)
        return
      when Prism::ClassVariableWriteNode, Prism::ClassVariableReadNode, Prism::ClassVariableOrWriteNode, Prism::ClassVariableOperatorWriteNode
        unit.cvars << [node.name, line, method&.name]
      when Prism::GlobalVariableWriteNode, Prism::GlobalVariableOrWriteNode, Prism::GlobalVariableOperatorWriteNode
        unit.gvars << [node.name, line, method&.name]
      when Prism::LocalVariableReadNode
        method.reads[node.name] += 1 if method
        return
      when Prism::LocalVariableWriteNode
        method&.handoffs&.push([node.name, node.value, line]) if handed_value?(node.value)
      when Prism::IfNode, Prism::UnlessNode, Prism::CaseNode, Prism::CaseMatchNode, Prism::WhileNode, Prism::UntilNode, Prism::AndNode, Prism::OrNode
        (method ? method.branches : unit.branches) << [node, in_block]
      when Prism::BlockNode, Prism::LambdaNode
        in_block = true
        bp = node.parameters
        params = bp.respond_to?(:parameters) && bp.parameters ? bp.parameters : nil
        if params
          (params.requireds + params.optionals + params.keywords).each { |p| method.reads[p.name] += 1 if method && p.respond_to?(:name) }
        end
      when Prism::BlockArgumentNode
        unit.symbols << node.expression.unescaped if node.expression.is_a?(Prism::SymbolNode)
      end
      node.compact_child_nodes.each { visit(_1, unit, method, nesting, singleton, in_block) }
    end

    def visit_call(node, unit, method, nesting, singleton, in_block)
      line = node.location.start_line
      recv = node.receiver
      args = node.arguments ? node.arguments.arguments : []
      kind, rname, resolved_name = receiver_shape(recv)
      call = Source::Call.new(receiver_kind: kind, receiver_name: rname, resolved: nil, name: node.name, args: args, line: line,
                              method: method&.name, block: node.block, node: node, arg_shapes: args.map { arg_shape(_1) })
      call.instance_variable_set(:@const, resolved_name)
      call.instance_variable_set(:@in_block, in_block)
      (method ? method.calls : unit.calls) << call
      unit.calls << call if method

      if recv.nil? && method.nil?
        record_macro(node, unit, args, line)
      end
      if recv.nil? && node.name == :raise then @literal_context = :raise end
      arith_or_loop(node, unit, method, in_block)

      visit(recv, unit, method, nesting, singleton, in_block) if recv && !recv.is_a?(Prism::ConstantReadNode) && !recv.is_a?(Prism::ConstantPathNode)
      add_ref(unit, resolved_name, node.name == :new ? :new : :call, line, method) if resolved_name
      previous = @literal_context
      @literal_context = :raise if recv.nil? && %i[raise warn fail].include?(node.name)
      @literal_context = :class_attr if args.first.is_a?(Prism::KeywordHashNode) && false
      args.each { visit_arg(_1, unit, method, nesting, singleton, in_block, node) }
      @literal_context = previous
      visit(node.block, unit, method, nesting, singleton, in_block) if node.block
    end

    # Hash values keep their key so a string under `class:` or `message:` can be told apart later.
    def visit_hash(hash, unit, method, nesting, singleton, in_block)
      hash.elements.each do |el|
        next visit(el, unit, method, nesting, singleton, in_block) unless el.is_a?(Prism::AssocNode)
        key = el.key.respond_to?(:unescaped) ? el.key.unescaped.to_s : nil
        visit(el.key, unit, method, nesting, singleton, in_block) unless el.key.is_a?(Prism::SymbolNode)
        previous = @literal_context
        @literal_context = key ? :"key_#{key}" : previous
        visit(el.value, unit, method, nesting, singleton, in_block)
        @literal_context = previous
      end
    end

    def visit_arg(arg, unit, method, nesting, singleton, in_block, call)
      if arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)
        visit_hash(arg, unit, method, nesting, singleton, in_block)
      else
        previous = @literal_context
        @literal_context = :"call_#{call.name}"
        visit(arg, unit, method, nesting, singleton, in_block)
        @literal_context = previous
      end
    end

    def record_macro(node, unit, args, line)
      return unless MACROS.include?(node.name)
      unit.macros << Source::Macro.new(name: node.name, args: args, line: line, block: node.block)
      names = args.filter_map { _1.respond_to?(:unescaped) ? _1.unescaped.to_s : (_1.is_a?(Prism::ConstantReadNode) || _1.is_a?(Prism::ConstantPathNode) ? const_name(_1) : nil) }
      case node.name
      when :include then unit.includes.concat(names); names.each { add_ref(unit, _1, :include, line, nil) }
      when :extend then unit.extends.concat(names); names.each { add_ref(unit, _1, :extend, line, nil) }
      when :prepend then unit.prepends.concat(names); names.each { add_ref(unit, _1, :prepend, line, nil) }
      when :output then unit.outputs[names.first.to_sym] = line if names.first
      when :input then unit.inputs[names.first.to_sym] = line if names.first
      when :attr_reader, :attr_accessor then unit.attr_readers.concat(names.map(&:to_sym))
      end
    end

    def arith_or_loop(node, unit, method, in_block)
      target = method || unit
      if %i[+ - * / % **].include?(node.name) && node.receiver && node.arguments
        lhs, rhs = node.receiver, node.arguments.arguments.first
        strings = [lhs, rhs].any? { _1.is_a?(Prism::StringNode) || _1.is_a?(Prism::InterpolatedStringNode) || _1.is_a?(Prism::ArrayNode) }
        target.arith << [node, in_block] unless strings
      elsif node.block && %i[each map select reject filter filter_map flat_map each_with_object inject reduce sum times each_pair each_with_index find detect any? all? none? count sort_by min_by max_by group_by partition].include?(node.name)
        target.loops << [node, in_block]
      end
    end

    def receiver_shape(recv)
      case recv
      when nil then [:none, nil, nil]
      when Prism::SelfNode then [:self, "self", nil]
      when Prism::ConstantReadNode, Prism::ConstantPathNode then [:const, const_name(recv), const_name(recv)]
      when Prism::InstanceVariableReadNode then [:ivar, recv.name.to_s, nil]
      when Prism::LocalVariableReadNode then [:local, recv.name.to_s, nil]
      when Prism::CallNode then [:call, recv.name.to_s, nil]
      else [:other, nil, nil]
      end
    end

    def arg_shape(arg)
      case arg
      when Prism::LocalVariableReadNode then [:local, arg.name]
      when Prism::CallNode then [:call, arg]
      when Prism::KeywordHashNode then [:kwargs, arg]
      when Prism::SymbolNode then [:symbol, arg.unescaped]
      when Prism::StringNode then [:string, arg.unescaped]
      else [:other, arg]
      end
    end

    def handed_value?(value)
      value.is_a?(Prism::CallNode) && value.name != :new && %i[ivar const local call].include?(receiver_shape(value.receiver).first)
    end

    def value_kind(value)
      case value
      when Prism::CallNode then value.name == :new ? :new : (landing_read?(value) ? :call_noargs : :call)
      when Prism::ConstantReadNode, Prism::ConstantPathNode then :const
      when Prism::LocalVariableReadNode then :local
      when Prism::HashNode, Prism::ArrayNode, Prism::StringNode, Prism::IntegerNode, Prism::SymbolNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode then :literal
      else :other
      end
    end

    # `screen`, `screen.form`, `Screen::TEXTS`, `@s.step`: a value read off one instance, not computed.
    def landing_read?(call)
      return false unless call.arguments.nil? && call.block.nil?
      case call.receiver
      when nil, Prism::SelfNode, Prism::ConstantReadNode, Prism::ConstantPathNode, Prism::InstanceVariableReadNode then true
      when Prism::CallNode then call.receiver.receiver.nil? && call.receiver.arguments.nil?
      else false
      end
    end

    # A value declared under `INHERENT_...` (or `@inherent_...`) is the reviewer saying its words are
    # the abstraction's own domain vocabulary, not this product's: R3's domain-vocabulary exception.
    INHERENT = /\A(INHERENT_|@inherent_)/

    def visit_declared_value(name, value, unit, method, nesting, singleton, in_block, line)
      return visit(value, unit, method, nesting, singleton, in_block) unless INHERENT.match?(name)
      unit.inherent_declarations << [name, line]
      @inherent += 1
      visit(value, unit, method, nesting, singleton, in_block)
    ensure
      @inherent -= 1 if INHERENT.match?(name)
    end

    def add_string(unit, text, line, method, interpolated)
      unit.strings << Source::Str.new(value: text, line: line, method: method&.name, context: @literal_context, interpolated: interpolated,
                                      words: text.scan(/[A-Za-z][a-z']+/), inherent: @inherent.positive?)
    end

    def add_ref(unit, name, kind, line, method)
      return if name.nil? || name.empty?
      ref = Source::Ref.new(name: name, resolved: nil, kind: kind, line: line, method: method&.name, callback: false)
      ref.instance_variable_set(:@nesting, unit.instance_variable_get(:@nesting))
      unit.refs << ref
      method&.refs&.push(ref)
    end

    def const_name(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode then node.full_name
      else nil
      end
    rescue Prism::ConstantPathNode::DynamicPartsError, NoMethodError
      nil
    end

    def loc_of(unit)
      lines = @source.lines[(unit.line - 1)...unit.end_line] || []
      lines.count { |l| s = l.strip; !s.empty? && !s.start_with?("#") }
    end
  end
end
