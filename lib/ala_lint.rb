require "set"
require_relative "ala_lint/finding"
require_relative "ala_lint/checks"
require_relative "ala_lint/config"
require_relative "ala_lint/source"
require_relative "ala_lint/parser"
require_relative "ala_lint/templates"
require_relative "ala_lint/layers"
require_relative "ala_lint/model"
require_relative "ala_lint/rules"
require_relative "ala_lint/report"

module AlaLint
  VERSION = "0.1.0"

  # Lint a project root (or an explicit Config) and return a Report.
  def self.analyze(root, **opts)
    config = root.is_a?(Config) ? root : Config.load(root, opts)
    model = Model.new(config)
    findings = Rules.run(model)
    Report.new(model, findings)
  end
end
