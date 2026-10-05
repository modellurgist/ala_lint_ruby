module AlaLint
  module Rules
    # R10: a data type (a record model, a Data or Struct) read by two units of one peer-forbidden
    # layer (scored when the type is theirs, the aggregate advisory when it sits lower), and a model
    # association that walks into another feature's table.
    class Data < Base
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
            elsif type.layer && type.layer.index > layer.index && type.data_type == :record
              flag(:r10_aggregate, type, type.line, "#{type.name} (#{type.layer.name}) is read by #{names} in #{layer.name}: a shared aggregate (ground symbol, §3.6.1) or Spray's shared entity (§6.17.2)? Send each consumer only the data it needs")
            end
          end
        end
      end

      def associations
        units.select { model.record?(_1) }.each do |u|
          u.macros.each do |m|
            next unless %i[has_many has_one belongs_to has_and_belongs_to_many].include?(m.name)
            target = m.args.first.respond_to?(:unescaped) ? m.args.first.unescaped.to_s : nil
            next unless target
            klass = association_class(target, m)
            next if m.name == :belongs_to && config.identity_models.include?(klass)
            why = m.name == :belongs_to ? "reads another feature's record through #{klass}; if #{klass} is only the shared identity, list it under identity_models" :
                  "lets a feature walk into another's table (#{klass})"
            flag(:r10, u, m.line, "#{u.name} #{m.name} :#{target}: #{why} (R10, §6.17.2)")
          end
        end
      end

      def association_class(target, macro)
        kw = macro.args.find { _1.is_a?(Prism::KeywordHashNode) }
        cn = kw&.elements&.find { _1.is_a?(Prism::AssocNode) && _1.key.respond_to?(:unescaped) && _1.key.unescaped == "class_name" }
        return cn.value.unescaped if cn&.value.is_a?(Prism::StringNode)
        singular = %i[has_many has_and_belongs_to_many].include?(macro.name) ? target.sub(/ies\z/, "y").sub(/s\z/, "") : target
        singular.split("_").map(&:capitalize).join
      end
    end
  end
end
