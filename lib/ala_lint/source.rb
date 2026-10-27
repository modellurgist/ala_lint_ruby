module AlaLint
  # The facts a file yields, as plain structs the rules read. A Unit is one abstraction's worth of
  # source: a class or module with its own members (nested classes qualify to it), an ERB template,
  # or a file of top-level statements. The rules never touch Prism nodes they didn't ask for.
  module Source
    Unit = Struct.new(
      :name, :file, :line, :end_line, :kind, :loc, :superclass, :includes, :extends, :prepends,
      :methods, :constants, :refs, :calls, :literals, :strings, :ivar_writes, :cvars, :gvars,
      :header_comment, :tag, :outputs, :inputs, :macros, :symbols, :texts, :attr_readers, :data_type,
      :branches, :arith, :loops, :layer, :body_nodes, :lambda_ivar_writes, :inherent_declarations, :assigns, :constant_values,
      :ports, :wired, keyword_init: true
    ) do
      def template? = kind == :template
      def script? = kind == :script
      def method_at(line) = methods.select { _1.line <= line && line <= _1.end_line }.min_by { _1.end_line - _1.line }
      def public_methods_list = methods.select { _1.visibility == :public && !_1.singleton }
      # The fields and locals a composition lists in `parts`, hands to `run` or joins with `wire_to`.
      def wired?(name) = wired.include?(name)
      def references?(unit_name) = refs.any? { _1.resolved == unit_name }
      # The values a local (in `method`) or a field (anywhere in the unit) is ever assigned.
      def assigned_values(name, method) = assigns.filter_map { |scope, n, v| v if n == name && (name.start_with?("@") || scope == method) }
    end

    Method = Struct.new(:name, :line, :end_line, :visibility, :singleton, :params, :keyword_defaults,
                        :body, :reads, :calls, :refs, :unit, :ivar_writes, :simple_body, :branches, :arith, :loops, :handoffs, :wiring_tables,
                        keyword_init: true)

    # A reference from one unit to a constant, with how it was used (call, new, superclass, mixin, const).
    Ref = Struct.new(:name, :resolved, :kind, :line, :method, :callback, keyword_init: true)

    # A call site: the receiver's shape (const/ivar/local/self/none/other), the resolved unit when the
    # receiver is a project constant, the message, and the argument nodes.
    Call = Struct.new(:receiver_kind, :receiver_name, :resolved, :name, :args, :line, :method, :block, :node, :arg_shapes, keyword_init: true)

    Literal = Struct.new(:value, :line, :method, :context, keyword_init: true)
    Str = Struct.new(:value, :line, :method, :context, :interpolated, :words, :inherent, keyword_init: true)
    IvarWrite = Struct.new(:name, :line, :method, :in_block, :operator, :value_kind, keyword_init: true)
    Macro = Struct.new(:name, :args, :line, :block, keyword_init: true)
    # A port with the class or module that declares it: a nested class's own header documents its
    # ports, not the enclosing unit's. `owner` nil means the unit itself.
    Port = Struct.new(:name, :direction, :line, :owner, :owner_line, :owner_header, keyword_init: true)
  end
end
