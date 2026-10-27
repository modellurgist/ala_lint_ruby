module AlaLint
  module Rules
    # What every rule group shares: the model, a findings list, and the vocabulary of layers.
    class Base
      # Rails calls that route an outcome (render, redirect) rather than compute one.
      ROUTING = %i[redirect_to render head respond_to format turbo_stream redirect_back_or_to].freeze
      LITERALS = [Prism::StringNode, Prism::SymbolNode, Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode, Prism::NilNode,
                  Prism::TrueNode, Prism::FalseNode, Prism::ConstantReadNode, Prism::ConstantPathNode].freeze

      attr_reader :model, :findings

      def initialize(model)
        @model = model
        @findings = []
      end

      def run
        check
        @findings
      end

      private

      def config = model.config
      def layered? = model.layered?
      def units = model.units
      def flag(check, unit, line, message) = @findings << Finding.new(check: check, message: message, unit: unit.name, file: model.relative(unit.file), line: line)
      def composition?(unit) = model.composition?(unit)
      def below?(unit) = model.below_composition?(unit)
      def bottom?(unit) = model.bottom?(unit)
      def layer_name(unit) = unit.layer&.name || "unassigned"
      def short(name) = name.to_s.split("::").last
      def method_name(m) = m ? "##{m}" : ""

      # A value written into the source: a literal, a constant, or a list or map of them.
      def literal_value?(node)
        case node
        when *LITERALS then true
        when Prism::ArrayNode then node.elements.all? { literal_value?(_1) }
        when Prism::HashNode, Prism::KeywordHashNode then node.elements.all? { _1.is_a?(Prism::AssocNode) && literal_value?(_1.key) && literal_value?(_1.value) }
        when Prism::CallNode then node.name == :freeze && node.arguments.nil? && literal_value?(node.receiver)
        else false
        end
      end

      def keyword_arg(args, key)
        args.grep(Prism::KeywordHashNode).flat_map(&:elements).find { _1.is_a?(Prism::AssocNode) && _1.key.respond_to?(:unescaped) && _1.key.unescaped == key }&.value
      end

      # A value picked from a literal table by a key: `RATES.fetch(kind)`, `NAMES[i]`, `{ a: "x" }[step]`.
      def literal_pick?(node)
        node.is_a?(Prism::CallNode) && %i[[] fetch dig].include?(node.name) && literal_value?(node.receiver) &&
          !node.arguments.nil? && node.arguments.arguments.drop(1).all? { literal_value?(_1) }
      end
    end
  end
end
