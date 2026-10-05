module AlaLint
  # The declared layer map (top first) and the assignment of each unit to a layer, most-specific-wins:
  # the unit's own `@ala_layer` tag, then a `uses:` match on its superclass or mixins, then the first
  # layer whose `paths:` or `namespaces:` pattern matches. Layers are declared, never inferred.
  class Layers
    Layer = Data.define(:name, :index, :paths, :namespaces, :uses, :composition, :peer_ok, :persistence) do
      def peer_forbidden? = !composition && !peer_ok
    end

    attr_reader :layers, :errors

    def initialize(spec)
      @layers = spec.each_with_index.map do |l, i|
        Layer.new(name: l[:name].to_sym, index: i, paths: Array(l[:paths]), namespaces: Array(l[:namespaces]), uses: Array(l[:uses]),
                  composition: l.key?(:composition) ? l[:composition] : i.zero?, peer_ok: l[:peer_ok] || false, persistence: l[:persistence] || false)
      end
      @errors = []
    end

    def names = @layers.map(&:name)
    def bottom = @layers.last
    def composition_layers = @layers.select(&:composition)
    def [](name) = @layers.find { _1.name == name.to_sym }

    def assign(unit, relative_file)
      if unit.tag
        layer = self[unit.tag]
        @errors << [unit, unit.tag] unless layer
        return layer
      end
      used = [unit.superclass, *unit.includes, *unit.extends].compact
      by_use = @layers.find { |l| l.uses.any? { |re| used.any? { re.match?(_1) } } }
      return by_use if by_use
      @layers.find { |l| l.paths.any? { _1.match?(relative_file) } || l.namespaces.any? { _1.match?(unit.name) } }
    end
  end
end
