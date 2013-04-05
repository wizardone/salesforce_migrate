$LOAD_PATH.unshift File.dirname(__FILE__)

require 'optparse'
require 'csv'
require 'yaml'
require 'logger'
require 'fileutils'
require 'databasedotcom'
require 'sugarcrm'
require 'mail'
require 'active_support/core_ext'
require 'active_record'
require 'fields'
require 'export'
require 'import'
require 'mailer'

module SalesforceMigration
	module Runner
		extend self

		# Start the migration dependening on command line argument: `initial_run` or `update`
		def start
			options = {}
			# Where do we need to store the csvs?
			options[:csv_dir] = "/var/sugarcrm/csv"
			options[:log_dir] = "/var/log/sugarcrm"
			options[:config_file] = File.join(File.dirname(__FILE__), "../config/credentials.yaml")
			@log_dir = options[:log_dir]
			create_logger
			optparse = OptionParser.new do |opts|
				opts.banner = "Usage: sf_migrate [options]"
				opts.on("-a", "--action NAME", "") do |action|
					options[:action] = action
				end
				opts.on("-f", "--config_file CONFIG_FILE", "") do |f|
					options[:config_file] = File.expand_path(f) if File.exists? f
				end 
				opts.on("-c", "--csv_dir CSV_DIR", "") do |c|
					options[:csv_dir] = c
				end
				opts.on("-l", "--log_dir LOG_DIR", "") do |l|
					options[:log_dir] = l
				end
				opts.on("-m", "--send_mail SEND_MAIL", "") do |m|
					options[:send_mail] = m
				end
			end
			optparse.parse!
			if options[:action].nil?
				puts optparse
				exit
			else
				begin
					SalesforceMigration::Export.new(options)
					SalesforceMigration::Import.new(options)
					SalesforceMigration::Mailer.new(options)
				rescue => e
	      	@logger.error(e)
				end
			end
		end
		
		def create_logger
      original_formatter = Logger::Formatter.new
      today = lambda { Date.today.to_s }
      dir = "#{@log_dir}/#{today.call}"
      file = "#{dir}/migration.log"
      FileUtils.mkdir_p(dir) unless Dir.exists? dir
      @logger = Logger.new(file)
      @logger.formatter = proc { |severity, datetime, progname, msg|
        original_formatter.call("IMPORT", datetime, progname, msg)
      }
      @logger
    end
	  
	end
end