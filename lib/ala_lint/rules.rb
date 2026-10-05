require_relative "rules/base"
require_relative "rules/coupling"
require_relative "rules/state"
require_relative "rules/literals"
require_relative "rules/contracts"
require_relative "rules/naming"
require_relative "rules/minimality"
require_relative "rules/ports"
require_relative "rules/data"
require_relative "rules/composition"

module AlaLint
  module Rules
    ALL = [Coupling, State, Literals, Contracts, Naming, Minimality, Ports, Data, Composition].freeze

    def self.run(model)
      ALL.flat_map { _1.new(model).run }.reject { model.config.off?(_1.check) }
    end
  end
end
