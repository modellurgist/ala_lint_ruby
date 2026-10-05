module AlaLint
  # The effective settings of one run: the durable `.ala_lint.rb` hash, overridden by the CLI for one
  # run. Each check ends up with a level (:off, :advisory, :scored) and its thresholds.
  class Config
    LEVELS = %i[off advisory scored].freeze
    DEFAULT_PATHS = %w[app lib config/routes.rb].freeze
    DEFAULT_EXCLUDE = [%r{/assets/}, %r{/javascript/}, %r{/views/pwa/}, %r{/channels/application_cable/}].freeze

    attr_reader :root, :paths, :layers, :exclude, :min_score, :identity_models, :require_layers,
                :tier, :enforce, :disable, :limit, :format, :raw

    def self.load(root, argv_opts = {})
      file = argv_opts[:config] || File.join(root, ".ala_lint.rb")
      raw = File.exist?(file) ? eval(File.read(file), TOPLEVEL_BINDING.dup, file) : {}
      raise ArgumentError, "#{file} must evaluate to a Hash" unless raw.is_a?(Hash)
      new(root, raw, argv_opts)
    end

    def initialize(root, raw = {}, opts = {})
      @root = File.expand_path(root)
      @raw = raw
      @paths = (opts[:paths].to_a.empty? ? Array(raw[:paths] || DEFAULT_PATHS) : opts[:paths]).map { File.expand_path(_1, @root) }
      @layers = opts[:layers] || raw[:layers]
      @exclude = DEFAULT_EXCLUDE + Array(raw[:exclude])
      @min_score = opts[:min_score] || raw[:min_score]
      @identity_models = Array(raw[:identity_models]).map(&:to_s)
      @require_layers = opts[:require_layers] || raw[:require_layers] || false
      @tier = opts[:tier] || :default
      @enforce = Array(opts[:enforce]).map(&:to_sym)
      @disable = Array(opts[:disable]).map(&:to_sym)
      @limit = opts[:limit] || 40
      @format = opts[:format] || :text
      @checks = build_checks(raw[:checks] || {}, opts[:set] || {})
    end

    def level(check) = @checks.fetch(check)[:level]
    def threshold(check, key) = @checks.fetch(check)[key]
    def scored?(check) = level(check) == :scored
    def off?(check) = level(check) == :off
    def layered? = !@layers.nil?

    # What a run changed from the defaults, so the report can say what it skipped.
    def params
      {
        root: @root, paths: @paths.map { relative(_1) }, tier: @tier,
        enforce: @enforce, disabled: Checks::ALL.map(&:name).select { off?(_1) },
        downgraded: Checks::ALL.select { _1.tier == :required && level(_1.name) == :advisory }.map(&:name),
        layers: layered? ? @layers.map { _1[:name] }.join(" > ") : "(none)",
        thresholds: Checks::ALL.flat_map { |c| c.thresholds.keys.map { |k| ["#{c.name}.#{k}", threshold(c.name, k)] } }.to_h,
        identity_models: @identity_models, min_score: @min_score
      }
    end

    def relative(path) = path.start_with?(@root) ? path.delete_prefix(@root).delete_prefix("/") : path

    private

    def build_checks(file_checks, cli_set)
      Checks::ALL.to_h do |c|
        setting = file_checks[c.name] || file_checks[c.name.to_s]
        level = tier_level(c)
        thresholds = c.thresholds.dup
        case setting
        when Symbol, String then level = normalize_level(setting)
        when Hash
          level = normalize_level(setting[:level]) if setting[:level]
          thresholds.merge!(setting.slice(*thresholds.keys))
        end
        level = :scored if @enforce.include?(c.name)
        level = :off if @disable.include?(c.name)
        cli_set.each { |k, v| thresholds[k.split(".").last.to_sym] = v if k.start_with?("#{c.name}.") }
        [c.name, thresholds.merge(level: level)]
      end
    end

    def tier_level(check)
      case check.tier
      when :required then :scored
      when :advisory then @tier == :default ? :advisory : :scored
      when :aspirational then @tier == :super_strict ? :scored : :advisory
      else :advisory
      end
    end

    def normalize_level(value)
      v = value.to_sym
      raise ArgumentError, "check level must be one of #{LEVELS.join(', ')}, got #{value.inspect}" unless LEVELS.include?(v)
      v
    end
  end
end
