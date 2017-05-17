require 'logger'


module QuietAssets

  # Actually, this is not going to work properly. Even though it might keep
  # track of all the threads properly, it will still turn off logging globally
  # while any asset thread is working. So even normal threads running at that
  # time will be silenced. Only solution is separate loggers, or for the
  # logger to act conditionally on the current thread.
  #module WorkingThreads
    #require 'thread'

    #@semaphore = Mutex.new
    #@num_asset_threads = 0

    #def self.register_entry
      #@semaphore.synchronize do
        #puts "Registering entry for #{Thread.current}"

        #if @num_asset_threads == 0
          #@original_log_level = Rails.logger.level
          #Rails.logger.level = Logger::ERROR
        #end

        #@num_asset_threads += 1
      #end
    #end

    #def self.register_exit
      #@semaphore.synchronize do
        #if @num_asset_threads == 0
          #return
        #elsif @num_asset_threads == 1
          #puts "Registering exit for #{Thread.current}"
          #Rails.logger.level = @original_log_level
          #@num_asset_threads -= 1
        #elsif @num_asset_threads > 1
          #puts "Registering exit for #{Thread.current}"
          #@num_asset_threads -= 1
          #puts "Threads remaining: #{@num_asset_threads}"
        #elsif @num_asset_threads < 0
          #raise "Num asset threads = #{@num_asset_threads}"
        #end
      #end
    #end
  #end

  module AssetThreadRegistry
    require 'thread'
    require 'set'

    @semaphore = Mutex.new
    @asset_threads = Set.new

    def self.register_entry(thread)
      @semaphore.synchronize do
        #puts "Registering entry for #{thread}"

        if @asset_threads.empty?
          @original_log_level = Rails.logger.level
          #puts "Saving original log level: #{@original_log_level}"
          Rails.logger.level = Logger::ERROR
        end

        @asset_threads << thread
      end
    end

    def self.register_exit(thread)
      @semaphore.synchronize do
        if @asset_threads.member?(thread)
          #puts "Registering exit for #{thread}"
          Rails.logger.level = @original_log_level
          @asset_threads.delete(thread)
          #puts "Threads remaining: #{@original_log_level}"
        else
          #puts "Skipping non-asset thread #{thread}"
        end
      end
    end

    def self.registered?(thread)
      @asset_threads.member?(thread)
    end
  end

  ActiveSupport::Logger.class_eval do
    #def add_with_quiet_assets(severity, *args)
    def add_with_quiet_assets(severity, message = nil, progname = nil)
      #unless severity >= 4

      #puts "Args: #{[severity, message, progname]}"
      #if message == nil && progname == nil
        #puts caller[0..5].join("\n")
      #end

        if AssetThreadRegistry.registered?(Thread.current)
          #puts "Skipping logging for #{Thread.current}"
          return
        else
          if block_given?
            block = Proc.new
            add_without_quiet_assets(severity, message, progname, &block)
          else
            add_without_quiet_assets(severity, message, progname)
          end
        end
      #end
    end
    alias_method_chain :add, :quiet_assets
  end

  class Engine < ::Rails::Engine
    # Set as true but user can override it
    config.quiet_assets = true
    config.quiet_assets_paths = []

    initializer 'quiet_assets', :after => 'sprockets.environment' do |app|
      next unless app.config.quiet_assets
      # Parse PATH_INFO by assets prefix
      paths = [ %r[\A/{0,2}#{app.config.assets.prefix}] ]
      # Add additional paths
      paths += [*config.quiet_assets_paths]
      ASSETS_REGEX = /\A(#{paths.join('|')})/
      KEY = 'quiet_assets.old_level'
      app.config.assets.logger = false

      # Just create an alias for call in middleware
      Rails::Rack::Logger.class_eval do
        def call_with_quiet_assets(env)
          is_asset_req = false
          begin
            if (is_asset_req = env['PATH_INFO'] =~ ASSETS_REGEX)
              #WorkingThreads.register_entry
              AssetThreadRegistry.register_entry(Thread.current)
            end
            call_without_quiet_assets(env)
          ensure
            #WorkingThreads.register_exit if is_asset_req
            AssetThreadRegistry.register_exit(Thread.current)
          end
        end
        alias_method_chain :call, :quiet_assets
      end
    end
  end
end
