require 'requirejs/rails/builder'
require 'requirejs/rails/config'

require 'fileutils'
require 'pathname'

require 'sprockets'
require 'tempfile'

require 'active_support/ordered_options'

namespace :requirejs do

  # From Rails 3 assets.rake; we have the same problem:
  #
  # We are currently running with no explicit bundler group
  # and/or no explicit environment - we have to reinvoke rake to
  # execute this task.
  def invoke_or_reboot_rake_task(task)
    if ENV['RAILS_GROUPS'].to_s.empty? || ENV['RAILS_ENV'].to_s.empty?
      ruby_rake_task task
    else
      Rake::Task[task].invoke
    end
  end

  def requirejs
    @requirejs ||= ActiveSupport::OrderedOptions.new
  end

  task :clean => ["requirejs:setup"] do
    FileUtils.remove_entry_secure(requirejs.config.source_dir, true)
    FileUtils.remove_entry_secure(requirejs.driver_path, true)
  end

  task :setup => ["assets:environment"] do
    unless Rails.application.config.assets.enabled
      warn "Cannot precompile assets if sprockets is disabled. Please set config.assets.enabled to true"
      exit
    end

    # Ensure that action view is loaded and the appropriate
    # sprockets hooks get executed
    _ = ActionView::Base

    requirejs.env = Rails.application.assets

    # Preserve the original asset paths, as we'll be manipulating them later
    requirejs.env_paths = requirejs.env.paths.dup
    requirejs.config = Rails.application.config.requirejs
    requirejs.builder = Requirejs::Rails::Builder.new(requirejs.config)
    requirejs.manifest = {}
  end

  task :test_node do
    begin
      `node -v`
    rescue Errno::ENOENT
      STDERR.puts <<-EOM
Unable to find 'node' on the current path, required for precompilation
using the requirejs-ruby gem. To install node.js, see http://nodejs.org/
OS X Homebrew users can use 'brew install node'.
EOM
      exit 1
    end
  end

  namespace :precompile do
    task :all => ["requirejs:precompile:prepare_source",
                  "requirejs:precompile:generate_rjs_driver",
                  "requirejs:precompile:run_rjs",
                  "requirejs:precompile:digestify_and_compress"]

    task :disable_js_compressor do
      # Ensure that Sprockets doesn't try to compress assets before they hit
      # r.js.  Failure to do this can cause a build which works in dev, but
      # emits require.js "notloaded" errors, etc. in production.
      Rails.application.config.assets.js_compressor = false
    end

    # Invoke another ruby process if we're called from inside
    # assets:precompile so we don't clobber the environment
    #
    # We depend on test_node here so we'll fail early and hard if node
    # isn't available.
    task :external => ["requirejs:test_node"] do
      ruby_rake_task "requirejs:precompile:all"
    end

    # copy all assets to tmp/assets
    task :prepare_source => ["requirejs:setup",
                             "requirejs:clean"] do
      requirejs.config.source_dir.mkpath
      requirejs.env.each_logical_path do |logical_path|
        next unless requirejs.config.asset_allowed?(logical_path)
        if asset = requirejs.env.find_asset(logical_path)
          filename = requirejs.config.source_dir + asset.logical_path
          filename.dirname.mkpath
          asset.write_to(filename)
        end
      end
    end

    task :generate_rjs_driver => ["requirejs:setup"] do
      requirejs.builder.generate_rjs_driver
    end

    task :run_rjs => ["requirejs:setup",
                      "requirejs:test_node"] do
      requirejs.config.target_dir.mkpath

      puts `node "#{requirejs.config.driver_path}"`
      unless $?.success?
        raise RuntimeError, "Asset compilation with node failed."
      end
    end

    # Copy each built asset, identified by a named module in the
    # build config, to its Sprockets digestified name.
    task :digestify_and_compress => ["requirejs:setup"] do

  def process_asset(asset_name)
    puts '--------------------'
    puts asset_name
    puts '--------------------'
    asset_path = source_asset_path(asset_name)
    if File.directory? asset_path
      asset_path.entries.delete_if { |e| ['.','..'].include? e.to_s }.map { |e| File.join(asset_name, e)}.each { |a| process_asset(a) }
    else
      copy_compress_and_digest_asset(asset_name)
    end
  end

  def copy_compress_and_digest_asset(asset_name)
    copy_asset(asset_name)
    compress_and_add_digest asset_name
    requirejs.manifest[asset_name.to_s] = digest_name(asset_name).to_s
  end

  def copy_asset(asset_name)
    FileUtils.mkdir_p built_asset_path(asset_name).dirname
    FileUtils.cp source_asset_path(asset_name), built_asset_path(asset_name)
  end

  def source_asset_path(asset_name)
    requirejs.config.source_dir + asset_name
  end

  def compress_and_add_digest(asset_name)
    compress_asset built_asset_path(asset_name)
    add_digest_asset asset_name
  end

  def add_digest_asset(asset_name)
    built_asset, digest_asset = built_asset_path(asset_name), digest_path(asset_name)
    FileUtils.cp built_asset, digest_asset
    FileUtils.cp "#{built_asset}.gz", "#{digest_asset}.gz"
  end

  def digest_path(asset_name)
    requirejs.config.target_dir + digest_name(asset_name)
  end

  def digest_name(asset_name)
    asset_name.sub(/\.(\w+)$/) { |ext| "-#{requirejs.builder.digest_for(built_asset_path(asset_name))}#{ext}" }
  end

  def built_asset_path(asset_name)
    requirejs.config.target_dir + asset_name
  end

  def compress_asset(asset_path)
    File.open("#{asset_path}.gz",'wb') do |f|
      zgw = Zlib::GzipWriter.new(f, Zlib::BEST_COMPRESSION)
      zgw.write asset_path.read
      zgw.close
    end
  end
      requirejs.config.source_dir.entries.delete_if { |e| ['.','..'].include? e.to_s }.each do |asset_name|
        process_asset(asset_name)

        requirejs.config.manifest_path.open('wb') do |f|
          YAML.dump(requirejs.manifest,f)
        end
      end
    end
  end

  desc "Precompile RequireJS-managed assets"
  task :precompile do
    invoke_or_reboot_rake_task "requirejs:precompile:all"
  end
end


task "assets:precompile" => ["requirejs:precompile:external"]
if ARGV[0] == "requirejs:precompile:all"
  task "assets:environment" => ["requirejs:precompile:disable_js_compressor"]
end
