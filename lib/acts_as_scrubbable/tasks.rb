
require 'rake'

namespace :scrub do
  desc "scrub all"
  task all: :environment do
    require 'highline/import'
    require 'term/ansicolor'
    require 'logger'
    require 'parallel'

    include Term::ANSIColor

    @logger = Logger.new($stdout)
    @logger.formatter = proc do |severity, datetime, progname, msg|
      "#{datetime}: [#{severity}] - #{msg}\n"
    end

    if ENV["SKIP_BEFOREHOOK"].blank?
      @logger.info "Running before hook".red
      ActsAsScrubbable.execute_before_hook
    end

    db_host, db_name = ActiveRecord::Base.connection_config.values_at(:host, :database)

    @logger.warn "Please verify the information below to continue".red
    @logger.warn "Host: ".red + " #{db_host}".white
    @logger.warn "Database: ".red + "#{db_name}".white

    unless ENV["SKIP_CONFIRM"] == "true"
      answer = ask("Type '#{db_host}' to continue. \n".red + '-> '.white)

      unless answer == db_host
        @logger.error "exiting ...".red
        exit
      end
    end

    @logger.warn "Scrubbing classes".red

    Rails.application.eager_load! # make sure all the classes are loaded

    @total_scrubbed = 0

    ar_classes = ActiveRecord::Base.descendants.select(&:scrubbable?).sort_by(&:to_s)

    # if the ENV variable is set
    unless ENV["SCRUB_CLASSES"].blank?
      class_list = ENV["SCRUB_CLASSES"].split(",")
      ar_classes &= class_list.map {|_class_str| _class_str.constantize }
    end

    @logger.info "Srubbable Classes: #{ar_classes.join(', ')}".white

    Parallel.each(ar_classes) do |ar_class|
      # Removing any find or initialize callbacks from model
      ar_class.reset_callbacks(:initialize)
      ar_class.reset_callbacks(:find)

      @logger.info "Scrubbing #{ar_class} ...".green

      scrubbed_count = 0

      ActiveRecord::Base.connection_pool.with_connection do
        relation = ar_class.respond_to?(:scrubbable_scope) ? ar_class.send(:scrubbable_scope) : ar_class.all

        if relation.sterilizable?
          scrubbed_count += relation.count
          relation.delete_all
          next
        end

        relation.find_in_batches(batch_size: 1000) do |batch|
          ActiveRecord::Base.transaction do
            batch.each do |obj|
              obj.scrub!
              scrubbed_count += 1
            end
          end
        end
      end

      @logger.info "#{scrubbed_count} #{ar_class} objects scrubbed".blue
    end

    ActiveRecord::Base.connection.verify!

    if ENV["SKIP_AFTERHOOK"].blank?
      @logger.info "Running after hook".red
      ActsAsScrubbable.execute_after_hook
    end

    @logger.info "Scrub Complete!".white
  end
end

desc "Links to scrub:all"
task :scrub => ['scrub:all']
