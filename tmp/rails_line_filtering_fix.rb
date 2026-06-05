# Workaround for Rails 8.1.1 line_filtering.rb ArgumentError
# This patch fixes the issue where run() is called with 3 args but expects 1..2
if Rails.env.test?
  Rails.application.config.after_initialize do
    begin
      $stderr.puts "DEBUG: Initializing Rails::LineFiltering patch" if ENV['DEBUG_TESTS']
      
      if defined?(Rails::LineFiltering)
        $stderr.puts "DEBUG: Rails::LineFiltering is defined" if ENV['DEBUG_TESTS']
        
        # Also patch run_suite to see if it's being called
        Minitest::Runnable.singleton_class.class_eval do
          alias_method :run_suite_original, :run_suite
          def run_suite(reporter, options = {})
            $stderr.puts "DEBUG: run_suite called for #{self.name}" if ENV['DEBUG_TESTS']
            $stderr.puts "DEBUG: filtered_methods = #{filter_runnable_methods(options).inspect}" if ENV['DEBUG_TESTS']
            run_suite_original(reporter, options)
          end
        end
        
        module Rails::LineFilteringPatch
          def run(*args)
            # Rails::LineFiltering#run expects (reporter, options = {})
            # But minitest's run_suite calls run(self, method_name, reporter) with 3 args
            # Handle the 3-arg case (minitest calling run on class with method_name)
            if args.length == 3 && args[1].is_a?(String) && args[0].is_a?(Class)
              # This is minitest calling: run(klass, method_name, reporter)
              # We need to call the instance run method, not the class method
              klass, method_name, actual_reporter = args
              instance = klass.new(method_name)
              result = instance.run
              actual_reporter.record(result) if actual_reporter.respond_to?(:record)
              return
            end
            
            # This is the Rails LineFiltering call: run(reporter, options = {})
            reporter = args[0]
            options = if args[1].is_a?(Hash)
                        args[1].dup
                      else
                        {}
                      end
            
            # Set the filter (original logic)
            options = options.merge(filter: Rails::TestUnit::Runner.compose_filter(self, options[:filter]))
            
            # The original calls super, but super fails in Rails 8.1.1
            # We need to manually execute tests
            # Get filtered methods and run them directly
            filter = options[:filter]
            
            # Debug: Check what we're working with
            $stderr.puts "DEBUG: Rails::LineFilteringPatch#run called for #{self.name}" if ENV['DEBUG_TESTS']
            $stderr.puts "DEBUG: Getting runnable_methods for #{self.inspect}" if ENV['DEBUG_TESTS']
            
            runnable_methods = self.runnable_methods
            $stderr.puts "DEBUG: runnable_methods = #{runnable_methods.inspect} (#{runnable_methods.size} methods)" if ENV['DEBUG_TESTS']
            
            filtered_methods = if filter
                                 $stderr.puts "DEBUG: Applying filter: #{filter.inspect}" if ENV['DEBUG_TESTS']
                                 filtered = runnable_methods.grep(filter)
                                 $stderr.puts "DEBUG: After filter: #{filtered.inspect} (#{filtered.size} methods)" if ENV['DEBUG_TESTS']
                                 filtered
                               else
                                 runnable_methods
                               end
            
            if filtered_methods.empty?
              $stderr.puts "DEBUG: WARNING - No methods to run! runnable_methods was empty." if ENV['DEBUG_TESTS']
              return
            end
            
            $stderr.puts "DEBUG: Running #{filtered_methods.size} test methods" if ENV['DEBUG_TESTS']
            # Run each test method using Minitest::Runnable.run
            # This avoids calling run_suite which would recurse
            filtered_methods.each_with_index do |method_name, idx|
              $stderr.puts "DEBUG: [#{idx + 1}/#{filtered_methods.size}] Running #{method_name}" if ENV['DEBUG_TESTS']
              Minitest::Runnable.run(self, method_name, reporter)
            end
            $stderr.puts "DEBUG: All test methods completed" if ENV['DEBUG_TESTS']
          end
        end
        
        unless Rails::LineFiltering.ancestors.include?(Rails::LineFilteringPatch)
          Rails::LineFiltering.prepend(Rails::LineFilteringPatch)
          $stderr.puts "DEBUG: Rails::LineFilteringPatch applied" if ENV['DEBUG_TESTS']
        else
          $stderr.puts "DEBUG: Rails::LineFilteringPatch already applied" if ENV['DEBUG_TESTS']
        end
      else
        $stderr.puts "DEBUG: WARNING - Rails::LineFiltering not defined!" if ENV['DEBUG_TESTS']
      end
      end
    rescue => e
      Rails.logger.warn("Could not apply LineFiltering patch: #{e.message}") if defined?(Rails.logger)
    end
  end
end
