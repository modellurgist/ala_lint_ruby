module AlaLint
  # The whole project as the rules see it: every unit, each reference resolved to the unit it names
  # (through Ruby's lexical nesting and the unit's mixins), each unit's layer, and the indexes the
  # rules share (edges between units, helper methods templates may call, data types).
  class Model
    FRAMEWORK_BASES = /\A(ApplicationRecord|ActiveRecord::Base|ApplicationController|ActionController::\w+|ApplicationJob|ActiveJob::Base|ApplicationMailer|ApplicationCable::\w+|Minitest::Test|ActiveSupport::TestCase|ActionDispatch::IntegrationTest|Rails::Application|Rails::Railtie|StandardError|RuntimeError|Struct|Data)\z/

    attr_reader :units, :config, :layers, :edges, :root, :acceptances

    def initialize(config)
      @config = config
      @root = config.root
      @acceptances = []
      @units = load_units
      @by_name = @units.to_h { [_1.name, _1] }
      @layers = config.layered? ? Layers.new(config.layers) : nil
      assign_layers
      resolve_refs
      @edges = build_edges
    end

    def unit(name) = @by_name[name]
    def relative(file) = config.relative(file)
    def layered? = !@layers.nil?
    def layer_of(unit) = unit.layer
    def composition?(unit) = unit.layer&.composition || false
    def bottom?(unit) = layered? && unit.layer == @layers.bottom
    def below_composition?(unit) = layered? && unit.layer && !unit.layer.composition
    def ruby_units = @units.reject(&:template?)
    def templates = @units.select(&:template?)
    def functions = @units.sum { _1.template? ? 1 : _1.methods.size }

    def data_type?(unit)
      unit.data_type ||= begin
        ar = unit.superclass.to_s.match?(/\A(ApplicationRecord|ActiveRecord::Base)\z/) || framework_subclass?(unit) && unit.superclass.to_s.end_with?("Record")
        ar ? :record : unit.superclass.to_s.match?(/\A(Data|Struct)\b/) ? :value : :none
      end
      unit.data_type != :none
    end

    def record?(unit) = data_type?(unit) && unit.data_type == :record
    # A value type with operations of its own is an abstraction both ends depend on (a Money); one
    # that is only fields is a DTO two readers share the meaning of (R10).
    def behaviour_type?(unit) = unit.data_type == :value && unit.methods.any? { !_1.singleton || _1.name != :new }
    def framework_subclass?(unit)
      return true if unit.superclass.to_s.match?(FRAMEWORK_BASES) || unit.superclass.to_s.match?(/::(Base|Test|TestCase)\z/)
      base = unit.superclass && @by_name[resolve_name(unit.superclass, unit)]
      base ? framework_subclass?(base) : false
    end
    def framework_base?(unit) = unit.name.match?(FRAMEWORK_BASES) || (unit.superclass.to_s.match?(FRAMEWORK_BASES) && unit.methods.empty?)

    # The public method names of the paradigm layers: the messages a port may send, so a
    # `respond_to?` check against one of them is a paradigm's, not a peer's.
    def paradigm_messages
      @paradigm_messages ||= begin
        named = @layers&.layers&.select { _1.name.to_s.match?(/paradigm/) }
        chosen = named&.any? ? named : [@layers&.layers&.[](-2) || @layers&.bottom].compact
        lower = @units.select { layered? && chosen.include?(_1.layer) }
        (lower.flat_map { |u| u.methods.map(&:name) } + %i[call push send_event request]).to_set
      end
    end

    def helper_methods
      @helper_methods ||= begin
        declared = @units.flat_map { |u| u.macros.select { _1.name == :helper }.flat_map { |m| m.args.filter_map { |a| a.is_a?(Prism::ConstantReadNode) || a.is_a?(Prism::ConstantPathNode) ? resolve_name(a.full_name, u) : nil } } }
        @units.select { _1.name.end_with?("Helper") || declared.include?(_1.name) }.flat_map { |u| u.methods.map { [_1.name, u.name] } }.to_h
      end
    end

    # Edges between units: [from_unit, to_unit, ref]. Same-unit refs and unresolved ones never appear.
    def resolve_name(name, unit) = resolve(name, unit.instance_variable_get(:@nesting) || [], unit)
    def edges_from(unit) = @edges.select { _1[0] == unit }
    def edges_to(unit) = @edges.select { _1[1] == unit }

    private

    def load_units
      files = config.paths.flat_map { |p| File.directory?(p) ? Dir.glob(File.join(p, "**", "*.{rb,erb}")) : [p] }
      files = files.select { File.file?(_1) }.reject { |f| config.exclude.any? { _1.match?(f) } }.sort
      files.flat_map do |f|
        @acceptances.concat(Acceptance.scan(File.read(f), relative(f)))
        f.end_with?(".erb") ? [Templates.parse(f, @root)] : Parser.parse(f, @root)
      rescue ArgumentError
        raise
      rescue StandardError => e
        warn "ala_lint: skipping #{relative(f)} (#{e.class}: #{e.message})"
        []
      end
    end

    def assign_layers
      return unless layered?
      @units.each { |u| u.layer = @layers.assign(u, relative(u.file)) }
    end

    def resolve_refs
      @units.each do |u|
        u.refs.each do |r|
          r.resolved = r.kind == :render ? resolve_partial(u, r.name.delete_prefix("partial:")) : resolve(r.name, r.instance_variable_get(:@nesting) || [], u)
        end
        u.calls.each do |c|
          const = c.instance_variable_get(:@const)
          c.resolved = resolve(const, u.instance_variable_get(:@nesting) || [], u) if const
        end
        callbacks = u.macros.select { _1.name.to_s.match?(/\A(after|before|around)_/) }.map(&:line)
        u.refs.each { _1.callback = true if callbacks.include?(_1.line) }
        if u.template?
          u.calls.each do |c|
            next unless c.receiver_kind == :none && helper_methods.key?(c.name) && helper_methods[c.name] != u.name
            u.refs << Source::Ref.new(name: c.name.to_s, resolved: helper_methods[c.name], kind: :helper, line: c.line, method: nil, callback: false)
          end
        else
          u.calls.each do |c|
            next unless c.receiver_kind == :call && c.receiver_name == "helpers" && helper_methods.key?(c.name)
            u.refs << Source::Ref.new(name: c.name.to_s, resolved: helper_methods[c.name], kind: :helper, line: c.line, method: c.method, callback: false)
          end
        end
      end
    end

    # Ruby's lookup, approximately: each enclosing scope, then the mixins of each, then the top level.
    # A path like `Screens::Checkout::TEXTS` resolves to the unit that defines its last segment.
    def resolve(name, nesting, unit)
      return nil if name.nil?
      scopes = nesting.size.downto(0).map { nesting.first(_1) }
      mixins = (unit.includes + unit.extends).flat_map { |m| scopes.map { |s| (s + [m]).join("::") } }
      candidates = scopes.map { (_1 + [name]).join("::") } + mixins.map { "#{_1}::#{name}" } + [name]
      candidates.each do |full|
        return nil if full == unit.name
        return full if @by_name.key?(full)
        parts = full.split("::")
        next if parts.size < 2
        prefix = parts[0...-1].join("::")
        next unless (owner = @by_name[prefix]) && owner.constants.key?(parts.last)
        return nil if prefix == unit.name
        return prefix
      end
      nil
    end

    def resolve_partial(unit, target)
      dir, base = target.include?("/") ? [File.join("app/views", File.dirname(target)), File.basename(target)] : [File.dirname(relative(unit.file)), target]
      candidate = File.join(dir, "_#{base}")
      @by_name.key?(candidate) ? candidate : nil
    end

    def build_edges
      @units.flat_map do |u|
        u.refs.select { _1.resolved && _1.resolved != u.name }.map { [u, @by_name[_1.resolved], _1] }
      end.uniq { [_1[0].name, _1[1].name, _1[2].kind, _1[2].line] }
    end
  end
end
