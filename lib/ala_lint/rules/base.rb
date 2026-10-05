module AlaLint
  module Rules
    # What every rule group shares: the model, a findings list, and the vocabulary of layers.
    class Base
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
    end
  end
end
