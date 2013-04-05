$LOAD_PATH.unshift File.dirname(__FILE__)

module SalesforceMigration
  class Export
    # Initilize migration export object, authenticates to SalesForce and start the export
    #
    # @param [Hash] options hash representing passed command line options
    def initialize(options)
      credentials     = YAML.load_file(options[:config_file])
      consumer_key    = credentials['salesforce_consumer_key']
      consumer_secret = credentials['salesforce_consumer_secret']
      username        = credentials['salesforce_username']
      password        = credentials['salesforce_password']
      @csv_dir        = options[:csv_dir]
      @action         = options[:action]
      @logger = SalesforceMigration::Runner::create_logger
      @logger.info("Export action started")
      @client = Databasedotcom::Client.new :client_id => consumer_key, :client_secret => consumer_secret
      @client.authenticate :username => username, :password => password
      
      @logger.info("Authentication to SalesForce successfull")
      start
      @logger.info("Export action ended successfully")
    end
    
    private
    def start
      %w(ISOs__c Agent__c Account Payment_Methods__c Banks__c MerchantToAPM__c ccrmbasic__Email__c Email_Association__c).each do |type|
        @logger.info "Writing CSV for #{type}"
        write_to_csv type
      end
    end
    
    # Generate and save CSV file for given type
    #
    # @param [String] type export type name
    def write_to_csv(type)
      fields    = return_fields(type)
      records   = get_records(type)
      file_name = generate_name(type)

      CSV.open(file_name, "wb:UTF-8") do |file|
        @logger.info "Opened #{file_name} for export"
        file << fields
        records.each do |record|
          arr = []
          fields.each do |field|
            arr << record.send(field)
            arr.map!(&method(:remove_quotes))
          end
          file << arr
        end
      end
    end
    
    # In order to fix the Invalid Session Id in SugarCRM we need to remove all
    # quotes from text fields, because they mess up the JSON object which comunicate with
    # our SugarCRM instance.
    # Note that on Mac we don`t need this method.
    def remove_quotes(field)
      field.gsub(/'/, "") if field.is_a? String
    end
    

    # Return the header fields
    def return_fields(type)
      return constantize "SalesforceMigration::Fields::#{type.slice(0..-4).upcase}_FIELDS" if type.end_with?("__c")
      return constantize "SalesforceMigration::Fields::#{type.upcase}_FIELDS"
    end

    # Get all records for specific type of object
    #
    # @param [String] type export type name
    #
    # @return [Databasedotcom::Collection] the requested records
    def get_records(type)
      if @action == 'initial_run'
        @logger.info "Getting all records from SalesForce for #{type}"
        records = get_all_sobjects(type)
      else
        @logger.info "Getting records for yesterday from SalesForce for #{type}"
        records  = @client.materialize(type)
        
        datetime = DateTime.now
        datetime = datetime -= 1
        records.query("lastmodifieddate >= #{datetime}")
      end
    end

    # Generates a name for CSV file depending on the action
    #
    # @param [String] type export type name
    #
    # @return [String] generated filename
    #
    # @example
    #   @action  = 'update'
    #   @csv_dir = '/tmp'
    #   generate_name('Account') #=> '/tmp/update/2012-07-07/Account_export.csv'
    def generate_name(type)
      if @action == 'initial_run'
        FileUtils.mkdir_p("#{@csv_dir}/initial/") unless Dir.exists? "#{@csv_dir}/initial/"
        "#{@csv_dir}/initial/#{type}_export.csv"
      else
        today = lambda { Date.today.to_s }
        dir = "#{@csv_dir}/update/#{today.call}"
        FileUtils.mkdir_p(dir) unless Dir.exists? dir
        "#{dir}/#{type}_export.csv"
      end
    end

    # Borrowed from activesupport/lib/active_support/inflector/methods.rb, line 212
    def constantize(camel_cased_word)
      names = camel_cased_word.split('::')
      names.shift if names.empty? || names.first.empty?
      constant = Object
      names.each do |name|
        constant = constant.const_defined?(name) ? constant.const_get(name) : constant.const_missing(name)
      end
      constant
    end

    # Get all objects of given type. Databasedotcom pulls only 250 records by query
    #
    # @param [String] type type of sobject
    #
    # @return [Array<Databasedotcom::Sobject::Sobject>] All available sobjects
    # Some objects, like Merchants and Emails are exported VIA a certain criteria
    def get_all_sobjects(type)
      case type
      when 'Account'
        records = @client.materialize(type).query("Agents__c != ''")
      when 'ccrmbasic__Email__c'
        records = @client.materialize(type).query("ccrmbasic__Contact__c != ''")
      else
        records = @client.materialize(type).all
      end
      sobjects = records.dup.to_a
      while records.next_page?
        sobjects += records.next_page
        records = records.next_page
      end
      sobjects
    end
  end
end