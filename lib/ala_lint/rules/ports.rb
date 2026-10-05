module AlaLint
  module Rules
    # R9 in the forms a Ruby source shows: a peer mixin or abstract base used as an interface, duck
    # typing to a peer's message, a container, locator or global configuration lookup below the
    # composition; plus the port advisories (ports not in the header comment, outputs no one wires).
    class Ports < Base
      LOCATORS = [
        [/\AImport\z/, nil, "a dependency-injection container resolving a collaborator by key (§3.10.1)"],
        [/\ADry::(Container|AutoInject)\z/, nil, "a dependency-injection container (§3.10.1)"],
        [/\ARails\z/, :configuration, "global configuration read to pick a collaborator or value (R9 \"No endpoints\", §4.4.2)"],
        [/\ARails\z/, :application, "Rails.application looked up below the composition (R9 \"No endpoints\")"],
        [/\AENV\z/, :[], "an environment lookup below the composition: the class picking its own configuration (R9, R3)"],
        [/\AENV\z/, :fetch, "an environment lookup below the composition: the class picking its own configuration (R9, R3)"]
      ].freeze

      def check
        units.each do |u|
          next if u.template?
          owned_interfaces(u)
          duck_typing(u) if below?(u) && !bottom?(u)
          locators(u) if below?(u)
          header_ports(u)
        end
        unwired_outputs
      end

      private

      def owned_interfaces(u)
        return unless layered? && u.layer
        u.refs.select { %i[include extend prepend].include?(_1.kind) && _1.resolved }.each do |r|
          target = model.unit(r.resolved)
          next unless target.layer && target.layer.index == u.layer.index && u.layer.peer_forbidden?
          flag(:r9, u, r.line, "#{u.name} #{r.kind}s #{target.name}, a peer: a module shared as an interface among peers is an owned interface (R9, §2.3.4); a paradigm port belongs below both")
        end
        return unless u.superclass && (base = model.unit(model.resolve_name(u.superclass, u)))
        abstract = base.calls.any? { _1.name == :raise && _1.args.any? { |a| a.is_a?(Prism::ConstantReadNode) && a.name == :NotImplementedError } }
        flag(:r9, u, u.line, "#{u.name} extends #{base.name}, an abstract base class: a port cannot be an abstract base class (R9, §6.2.1); implement a paradigm port instead") if abstract
      end

      def duck_typing(u)
        u.calls.each do |c|
          next unless c.name == :respond_to? && c.args.first.is_a?(Prism::SymbolNode) && !%i[none self].include?(c.receiver_kind)
          message = c.args.first.unescaped.to_sym
          next if model.paradigm_messages.include?(message)
          flag(:r9, u, c.line, "#{u.name}#{method_name(c.method)} checks respond_to?(:#{message}) on a collaborator: duck typing to a peer's own message is an owned interface (R9); send only a paradigm's messages")
        end
      end

      def locators(u)
        u.calls.each do |c|
          next unless c.receiver_kind == :const
          LOCATORS.each do |pattern, name, why|
            next unless pattern.match?(c.receiver_name) && (name.nil? || c.name == name)
            flag(:r9, u, c.line, "#{u.name}#{method_name(c.method)} uses #{c.receiver_name}.#{c.name}: #{why}")
          end
        end
      end

      def header_ports(u)
        return if composition?(u)
        declared = (u.outputs.keys + u.inputs.keys).map(&:to_s)
        return if declared.empty?
        missing = declared.reject { |p| u.header_comment.match?(/\b#{Regexp.escape(p)}\b/) }
        return if missing.empty?
        flag(:ports, u, u.line, "#{u.name} declares ports its header comment doesn't list (#{missing.join(', ')}): a reader of the wiring should see the ports without opening the body (R6, R9 §5.8.2)")
      end

      # An output name no composition mentions as a symbol is possibly never wired: a prompt for a
      # coverage test, never a defect.
      def unwired_outputs
        return unless layered?
        named = units.select { composition?(_1) }.flat_map(&:symbols).to_set
        units.each do |u|
          next unless below?(u)
          u.outputs.each do |name, line|
            next if named.include?(name.to_s)
            flag(:ports_unwired, u, line, "#{u.name} output :#{name} is named by no composition: unwired, or wired by a name the tool can't see (an R8 prompt for a coverage test)")
          end
        end
      end
    end
  end
end
