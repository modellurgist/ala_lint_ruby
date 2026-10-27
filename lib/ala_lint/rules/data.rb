module AlaLint
  module Rules
    # R10: a data type (a record model, a Data or Struct) read by two units of one peer-forbidden
    # layer (scored when the type is theirs, the aggregate advisory when it sits lower), and a model
    # association that walks into another feature's table.
    class Data < Base
      ASSOCIATIONS = %i[has_many has_one belongs_to has_and_belongs_to_many].freeze
      QUERIES = %i[includes joins left_joins left_outer_joins preload eager_load references].freeze

      def check
        return unless layered?
        shared_types
        associations
      end

      private

      def shared_types
        units.select { model.data_type?(_1) }.each do |type|
          readers = model.edges_to(type).reject { _1[2].kind == :new }.map(&:first).uniq.reject { _1 == type || composition?(_1) }
          readers.group_by { _1.layer }.each do |layer, group|
            next if layer.nil? || !layer.peer_forbidden? || group.size < 2
            names = group.map(&:name).join(", ")
            if type.layer && type.layer.index == layer.index
              flag(:r10, type, type.line, "#{type.name} is read by #{names}, peers in #{layer.name}: two features knowing the meaning of the same data (R10, §6.17.2); share an identity key and keep data private")
            elsif type.layer && type.layer.index > layer.index && !model.behaviour_type?(type)
              flag(:r10_aggregate, type, type.line, "#{type.name} (#{type.layer.name}) is read by #{names} in #{layer.name}: a shared aggregate (ground symbol, §3.6.1) or Spray's shared entity (§6.17.2)? Send each consumer only the data it needs")
            end
          end
        end
      end

      # Each association, declared on a record or configured on one from the composition. A `dependent:`
      # association on an identity, or one the composition configures, is the identity's lifecycle
      # (deleting it removes the rows keyed by it) until some unit reads or walks through it.
      def associations
        declarations.each do |record, m, site|
          target = m.args.first.respond_to?(:unescaped) ? m.args.first.unescaped.to_s : nil
          next unless target
          klass = association_class(target, m)
          next if m.name == :belongs_to && config.identity_models.include?(klass)
          lifecycle = %i[has_many has_one].include?(m.name) && keyword_arg(m.args, "dependent")
          reader = walks_through(target)
          next if lifecycle && !reader && (site != record || config.identity_models.include?(record.name))
          configured = site == record ? "" : " (configured in #{site.name})"
          why = if reader
                  "#{reader}: a feature walking into another's table (#{klass}); only a lifecycle no feature reads is the identity's own"
                elsif m.name == :belongs_to
                  "reads another feature's record through #{klass}; if #{klass} is only the shared identity, list it under identity_models"
                elsif lifecycle
                  "lets a feature walk into another's table (#{klass}); if #{record.name} is an identity and this only declares its lifecycle, list it under identity_models"
                else
                  "lets a feature walk into another's table (#{klass})"
                end
          flag(:r10, site, m.line, "#{record.name} #{m.name} :#{target}#{configured}: #{why} (R10, §6.17.2)")
        end
      end

      def declarations
        on_records = units.select { model.record?(_1) }.flat_map { |u| u.macros.select { ASSOCIATIONS.include?(_1.name) }.map { |m| [u, m, u] } }
        from_composition = units.select { composition?(_1) }.flat_map do |u|
          u.calls.filter_map do |c|
            record = c.receiver_kind == :const && ASSOCIATIONS.include?(c.name) && c.resolved && model.unit(c.resolved)
            [record, Source::Macro.new(name: c.name, args: c.args, line: c.line, block: c.block), u] if record && model.record?(record)
          end
        end
        on_records + from_composition
      end

      # The first unit that names the association: a call (`product.cart_items`), a query
      # (`includes(:cart_items)`), or a `through:`. By name, so a same-named method elsewhere counts too.
      def walks_through(target)
        name = target.to_sym
        units.each do |u|
          u.calls.each do |c|
            via = c.name == name || (QUERIES.include?(c.name) && c.args.any? { names_symbol?(_1, target) })
            return "#{u.name}#{method_name(c.method)} reads through it (#{model.relative(u.file)}:#{c.line})" if via
          end
          u.macros.each { |m| return "#{u.name} walks through it (#{model.relative(u.file)}:#{m.line})" if keyword_arg(m.args, "through")&.then { names_symbol?(_1, target) } }
        end
        nil
      end

      def names_symbol?(node, target)
        case node
        when Prism::SymbolNode then node.unescaped == target
        when Prism::ArrayNode then node.elements.any? { names_symbol?(_1, target) }
        when Prism::HashNode, Prism::KeywordHashNode then node.elements.any? { _1.is_a?(Prism::AssocNode) && (names_symbol?(_1.key, target) || names_symbol?(_1.value, target)) }
        else false
        end
      end

      def association_class(target, macro)
        cn = keyword_arg(macro.args, "class_name")
        return cn.unescaped if cn.is_a?(Prism::StringNode)
        singular = %i[has_many has_and_belongs_to_many].include?(macro.name) ? target.sub(/ies\z/, "y").sub(/s\z/, "") : target
        singular.split("_").map(&:capitalize).join
      end
    end
  end
end
