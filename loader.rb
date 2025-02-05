# frozen_string_literal: true

require "bundler/setup"
Bundler.setup

require_relative "config"
require "rack/unreloader"

REPL = false unless defined? REPL

Unreloader = Rack::Unreloader.new(
  reload: Config.development?,
  autoload: true,
  logger: if Config.development? && !REPL
            require "logger"
            Logger.new($stdout)
          end
) { Clover }

Unreloader.autoload("#{__dir__}/db.rb") { "DB" }
Unreloader.autoload("#{__dir__}/ubid.rb") { "UBID" }

AUTOLOAD_CONSTANTS = []

# Set up autoloads using Unreloader using a style much like Zeitwerk:
# directories are modules, file names are classes.
autoload_normal = ->(subdirectory, include_first: false) do
  # Copied from sequel/model/inflections.rb's camelize, to convert
  # file paths into module and class names.
  camelize = ->(s) do
    s.gsub(/\/(.?)/) { |x| "::#{x[-1..].upcase}" }.gsub(/(^|_)(.)/) { |x| x[-1..].upcase }
  end

  absolute = File.join(__dir__, subdirectory)
  rgx = Regexp.new('\A' + Regexp.escape((File.file?(absolute) ? File.dirname(absolute) : absolute) + "/") + '(.*)\.rb\z')
  last_namespace = nil

  Unreloader.autoload(absolute) do |f|
    full_name = camelize.call((include_first ? subdirectory + File::SEPARATOR : "") + rgx.match(f)[1])
    parts = full_name.split("::")
    namespace = parts[0..-2].freeze

    # Skip namespace traversal if the last namespace handled has the
    # same components, forming a fast-path that works well when output
    # is the result of a depth-first traversal of the file system, as
    # is normally the case.
    unless namespace == last_namespace
      scope = Object
      namespace.each { |nested|
        scope = if scope.const_defined?(nested, false)
          scope.const_get(nested, false)
        else
          Module.new.tap { scope.const_set(nested, _1) }
        end
      }
      last_namespace = namespace
    end

    # Reloading re-executes this block, which will crash on the
    # subsequently frozen AUTOLOAD_CONSTANTS.  It's also undesirable
    # to have re-additions to the array.
    AUTOLOAD_CONSTANTS << full_name unless AUTOLOAD_CONSTANTS.frozen?

    full_name
  end
end

%w[model lib clover.rb clover_web.rb clover_api.rb routes/clover_base.rb].each { autoload_normal.call(_1) }
%w[scheduling prog serializers serializers/web serializers/api].each { autoload_normal.call(_1, include_first: true) }

AUTOLOAD_CONSTANTS.freeze

if Config.production?
  AUTOLOAD_CONSTANTS.each { Object.const_get(_1) }
end
