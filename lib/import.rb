$LOAD_PATH.unshift File.dirname(__FILE__)

module SalesforceMigration
  # Workflow for import of specific object
  # 
  # import_agents -> load_file_for_import -> transform_csv_file -> prefix_sf_attribute_names
  #               -> transform_agents
  #               -> populate_sugar -> get_sugarcrm_module_type
  #                                 -> convert_string_to_datetime
  #                                 -> create_association -> find_sugarcrm_object
  #                                 -> create_user
  class Import

    # Initialize migration import object and start the import
    #
    # @param [Hash] options hash representing passed command line options
    def initialize(options)
      credentials = YAML.load_file(options[:config_file])
      url      = credentials['sugar_url']
      username = credentials['sugar_username']
      password = credentials['sugar_password']
      @csv_dir = options[:csv_dir]
      SugarCRM.connect(url, username, password)
      @action = options[:action]
      @isos, @agents, @merchants, @bank_accounts, @agent_users, @iso_users, @emails  = [], [], [], [], [], [], []
      @payment_to_merchants, @emails_to_merchants = [], []
      @logger = SalesforceMigration::Runner::create_logger
      @logger.info("Import action started")
      start
      @logger.info("Import action ended successfully")
    end
    
    private
    
    def start
      import_emails
      import_payment_methods
      import_isos
      import_agents
      import_merchants
      import_settlement_bank_accounts
      
      associate_records_to_groups
    end

    # Import methods. They load the csv file, for the given type
    # get rid of unnecessary information, transforms other fields, so
    # they can match the one in SugarCRM and calls for the populate_sugar method
    # which start the actual import. Keep in mind, that the order of the imports is important
    def import_isos
      records = load_file_for_import 'ISOs__c'
      records = transform_isos(records)
      populate_sugar(records, "iso")
    end

    def import_agents
      records = load_file_for_import 'Agent__c'
      records = transform_agents(records)
      populate_sugar(records, "agent")
    end

    def import_merchants
      records = load_file_for_import 'Account'
      records = transform_merchants(records)
      populate_sugar(records, "merchant")
    end

    def import_settlement_bank_accounts
      records = load_file_for_import 'Banks__c'
      records = transform_settlement_bank_accounts(records)
      populate_sugar(records, "settlement_bank_account")
    end

    def import_payment_methods
      records = load_file_for_import 'Payment_Methods__c'
      junction_records = load_file_for_import 'MerchantToAPM__c'
      # We don`t need db table to save the many-to-many associations between Merchant and Payment Method,
      # so we just store them in an array and use it later on
      junction_records.each do |jrecord|
        @payment_to_merchants << jrecord
      end
      populate_sugar(records, "payment_method")
    end
    
    def import_emails
      records = load_file_for_import 'ccrmbasic__Email__c'
      records = transform_emails(records)
      junction_records = load_file_for_import 'Email_Association__c'
      # We don`t need db table to save the many-to-many associations between Merchant and Payment Method,
      # so we just store them in an array and use it later on
      junction_records.each do |jrecord|
        @emails_to_merchants << jrecord
      end
      populate_sugar(records, "email")
    end
    
    # Load CSV for import
    #
    # @param [String] module_name name of the module
    #
    # @return [Array] parsed CSV file
    def load_file_for_import(module_name)
      if @action == 'initial_run'
        filename = "#{@csv_dir}/initial/#{module_name}_export.csv"
      else
        today = lambda { Date.today.to_s }
        dir = "#{@csv_dir}/update/#{today.call}"
        filename = "#{dir}/#{module_name}_export.csv"
      end
      @logger.error("Could not create or find a csv filename for module #{module_name}") unless defined? filename
      @logger.info("Loading CSV file #{filename} for import")
      csv_file = ::CSV.read(filename, :encoding => 'utf-8')
      transform_csv_file(csv_file)
    end

    # Load CSV file, removes headers and create a hash with the headers as keys
    #
    # @param [Array] file parsed CSV file
    #
    # @return [Array] transformed CSV file 
    def transform_csv_file(csv_file)
      @logger.info("Transforming CSV file")
      transformed = []
      headers = csv_file.shift
      headers.map!(&method(:prepare_custom_headers))

      csv_file.each do |row|
        transformed << Hash[headers.zip row]
      end
      prefix_sf_attribute_names transformed
    end
    
    #Remove the __c and lowercase the custom header fields, exported from Salesforce.
    #
    # @param [String] header
    def prepare_custom_headers(header)
      header.end_with?("__c") ? header.slice(0..-4).downcase : header.downcase
    end

    # Add sf_ prefix to all auto-generated attribute names from Salesforce
    #
    # @param [Array<SugarCRM::Namespace::Object>] records records to be prefixed
    #
    # @return [Array<SugarCRM::Namespace::Object>] returns the records
    def prefix_sf_attribute_names(records)
      sf_attribute_names = SalesforceMigration::Fields::SYSTEM_FIELDS
      records.each do |r|
        sf_attribute_names.each do |field|
          r["sf_#{field.downcase}"] = r[field]
          r.delete(field)
        end
      end
      records
    end

    def transform_isos(records)
      @logger.info("Transforming ISO fields")
      records.each do |record|
        record['general_c_chargeback_fee']   = record['general_conventional_chargeback_fee']
        record['general_c_commission_fee']   = record['general_conventional_commission_fee']
        record['general_c_transaction_fee']  = record['general_conventional_transaction_fee']
        record['general_nc_chargeback_fee']  = record['general_non_conventional_chargeback_fee']
        record['general_nc_commission_fee']  = record['general_non_conventional_commission_fee']
        record['general_nc_transaction_fee'] = record['general_non_conventional_transaction_fee']
        record.delete 'general_conventional_chargeback_fee'
        record.delete 'general_conventional_commission_fee'
        record.delete 'general_conventional_transaction_fee'
        record.delete 'general_non_conventional_chargeback_fee'
        record.delete 'general_non_conventional_commission_fee'
        record.delete 'general_non_conventional_transaction_fee'
      end
      records
    end

    def transform_agents(records)
      @logger.info("Transforming fields")
      records.each do |record|
        record['sf_iso'] = record['iso_company']
        record.delete 'iso_company'
      end
      records
    end

    def transform_merchants(records)
      @logger.info("Transforming Merchant fields")
      records.each do |record|
        record['sf_agent'] = record['agents']
        record['url'] = record['url'].to_s.gsub(/<[^>]*>|^[\n\r]*/, '')
        record['additional_url'] = record['additional_url'].to_s.gsub(/(<[^>]*>|^[\n\r]*)/, '')
        record.delete 'agents'
        record.delete 'sf_lastactivitydate'
        record.delete 'sf_lastmodifieddate'
        record.delete 'sf_region'
      end
      records
    end

    def transform_settlement_bank_accounts(records)
      @logger.info("Transforming Settlement Bank Account fields")
      records.each do |record|
        record['sf_iso'] = record['iso']
        record['sf_contract'] = record['contract']
        record['sf_merchant'] = record['merchant_2']
        record.delete 'merchant_2'
        record.delete 'iso'
        record.delete 'contract'
        record.delete 'sf_recruiter'
        record.delete 'sf_region'
      end
      records
    end
    
    def transform_emails(records)
      @logger.info("Transforming Email fields")
      records.each do |record|
        record['receiver'] = record['ccrmbasic__to']
        record['cc'] = record['ccrmbasic__cc']
        record['body'] = convert_characters(record['ccrmbasic__body']) unless record['ccrmbasic__body'].nil?
        
        record.delete 'ccrmbasic__to'
        record.delete 'ccrmbasic__cc'
        record.delete 'ccrmbasic__body'
      end
      records
    end

    # Convert all string datetime attributes to DateTime objects
    #
    # @param [SugarCRM::Namespace::Object] record the record which attributes must be converted
    #
    # @return [SugarCRM::Namespace::Object] the record
    def convert_string_to_datetime(record)
      record['sf_lastmodifieddate'] = record['sf_lastmodifieddate'].to_datetime if record['sf_lastmodifieddate']
      record['sf_createddate']      = record['sf_createddate'].to_datetime      if record['sf_createddate']
      record['sf_lastactivitydate'] = record['sf_lastactivitydate'].to_date     if record['sf_lastactivitydate']
      record
    end
    
    def convert_characters(string)
        string.gsub!(/\'/, '&apos;')
        string.gsub!(/'/, '')
        string.gsub!(/"/, '')
        string.gsub!(/\"/, '&quot;')
        string
      end

    # Populate SugarCRM with records
    #  If it's initial run, it will create all records from the CSV file
    #  If it's update, it will update existing records and create new if necessary
    #
    # @param [Array] records records to be inserted in SugarCRM
    # @param [String] type type of the object
    def populate_sugar(records, type)
      module_type = get_sugarcrm_module_type(type)
      case @action
      when 'initial_run'
          @logger.info("Creating new records for #{type} type")
          records.each do |record|
            create_sugar_record(module_type, record, type)
          end
      when 'update'
        records.each do |record|
          record = convert_string_to_datetime(record)
          existing_record = find_sugarcrm_object(type, 'sf_id', record['sf_id'])
          existing_record = existing_record.first if existing_record.is_a?(Array)
          if existing_record
            #TODO Nil values are not handled properly by SugarCRM in update_attributes, so we must transform them into blank values
            #remove this loop and use the main one!!
            record.each do |key, val|
              record[key] = "" if val.nil?
            end
            @logger.info("Updating record for #{type} #{record['name']}")
            existing_record.update_attributes!(record)
          else
            @logger.info("Creating new record for #{type} #{record['name']}")
            create_sugar_record(module_type, record, type)
          end
        end
      end
    end
    
    # Create the actual records and users in SugarCRM. Populates the var_pool
    def create_sugar_record(module_type, record, type)
      record = convert_string_to_datetime(record)

      obj = module_type.new(record)
      obj.save!
      obj = create_association(obj, type) unless %(email payment_method).include? type
      create_security_group_iso obj if type == 'iso'
      
      create_user(obj, type) if %(iso agent).include? type
      populate_var_pool(obj, type)
    end
    
    # Populates variables with SugarCRM objects.
    # We use them later on, when associating objects with Security Groups
    # Actually we don`t use @bank_accounts & @emails for now, but it`s probably a good idea to store the objects
    # @param [SugarCRM::Namespace::Object] obj object for which a user will be created
    # @param [String] type type of the object
    def populate_var_pool(obj, type)
      case type
      when 'merchant'
        @merchants << obj
      when 'settlement_bank_account'
        @bank_accounts << obj
      when 'iso'
        @isos << obj
      when 'agent'
        @agents << obj
      when 'email'
        @emails << obj
      end  
    end

    # Create association for agent, merchant, settlement bank Account, Email, Payment Method
    #   If it is agent, it will find the ISO by id and create the association
    #   If it is merchant, it will find the Agent, Payment Method, User and create the associations
    #   If it is Settlement Bank Account it will find the Merchant and create the associations
    # @param [SugarCRM::Namespace::Object] obj the object for which an association will be created
    # @param [String] type type of the object
    #
    # @return [SugarCRM::Namespace::Object] the object
    def create_association(obj, type)
      @logger.info("Creating association for #{type} #{obj.name}")
      case type
      when "agent"
        iso = find_sugarcrm_object('iso', 'sf_id', obj.sf_iso)
        obj.associate! iso if iso
      when "merchant"
        
        payment_method_id = find_payment_method_id(obj.sf_id)
        if payment_method_id
            payment_method = find_sugarcrm_object('payment_method', 'sf_id', payment_method_id)
            obj.associate! payment_method
        end
       
        email_id = find_email_id(obj.sf_id)
        if email_id
          email = find_sugarcrm_object('email', 'sf_id', email_id)
          obj.associate! email
        end
        
        agent = find_sugarcrm_object('agent', 'sf_id', obj.sf_agent)
        if agent
          obj.associate! agent
          obj.assigned_user_id = agent.assigned_user_id
        end
        
      when "settlement_bank_account"
        merchant = find_sugarcrm_object('merchant', 'sf_id', obj.sf_merchant)
        obj.associate! merchant if merchant
      end
      obj
    end

    # Create user associated with SugarCRM object
    # Default email: mail@example.com, default password: 123456
    # 
    # @param [SugarCRM::Namespace::Object] obj object for which a user will be created
    # @param [String] type type of the object 
    def create_user(obj, type)
        @logger.info("Creating user for #{type} #{obj.name}")
        user = SugarCRM::User.new
        user.user_name = (type == 'agent') ? obj.emerchantpay_agent_id : obj.emerchantpay_iso_id
        user.user_name ||= "EMP"
        user.last_name = obj.name
        user.type_c = type
        #user.email1 = obj.email_address || "mail@example.com"
        user.email1 = 'stefan@emerchantpay.com'
        user.status = 'Inactive'
        user.system_generated_password = false
        user.save!
        obj.assigned_user_id = user.id
        obj.save!
        
        populate_user_pool(user, type)
    end
    
    # Populates Users as SugarCRM objects.
    # We use them later on, when associating objects with Security Groups
    # @param [SugarCRM::Namespace::Object] Already created user object
    # @param [String] type type of the object
    def populate_user_pool(user, type)
      case type
      when 'iso'
        @iso_users << user
      when 'agent'
        @agent_users << user
      end
    end
    
    # Find records(payment methods, emails) in the junction object arrays, given the merchant_id
    # Both payment methods and emails have a many-to-many relationship with the merchant in Salesforce
    def find_payment_method_id(merchant_id)
      @payment_to_merchants.each do |record|
        return record['payment_methods'] if record['merchant'] == merchant_id.to_s
      end
      false
    end
    
    def find_email_id(merchant_id)
      @emails_to_merchants.each do |record|
        return record['email'] if record['merchant_name'] == merchant_id.to_s
      end
      false
    end
    
    #Creates the Security Group object in SugarCRM
    # @param [SugarCRM::Namespace::EmpIso] Iso object
    def create_security_group_iso(iso)
      @logger.info("Creating SecurityGroup #{iso.name}")
      sg = SugarCRM::SecurityGroup.new(:name => iso.name) unless find_sugarcrm_object('security_group','name', iso.name)
      sg.save! if sg
    end
    
    # Assign all records, that need to be in a Security Group, to the Group
    def associate_records_to_groups
      put_isos_into_iso_group
      put_agents_into_iso_group
      put_merchants_into_iso_group
    end

    def put_isos_into_iso_group
      if @isos
        @logger.info("Puting ISOs into ISO groups")
        role = SugarCRM::ACLRole.find_by_name("isos")
        @isos.each do |iso|
          sg = find_sugarcrm_object('security_group','name', iso.name)
          user   = SugarCRM::User.find_by_last_name(iso.name)
          iso.associate! sg
          user.associate! sg
          role.associate! sg
        end
      end
    end

    def put_agents_into_iso_group
      if @agents
        @logger.info("Putting agent records, agent users and agent role into ISO groups")
        @agents.each do |agent|
          sg = find_sugarcrm_object('security_group','name', agent.emp_iso.first.name) unless agent.emp_iso.empty?
          role = SugarCRM::ACLRole.find_by_name('agents')
            if sg
              user = SugarCRM::User.find_by_last_name(agent.name)
              @logger.info("Puting Agent #{agent.name} in Security Group #{sg.name}")
              agent.associate! sg
              user.associate! sg
              role.associate! sg 
            end  
        end
      end
    end
    
    # Bank accounts, Emails and Payment Methods must be inserted from this method, not separately,
    # because we need to use the merchant object loop, which provides us with the ready merchant id, with which 
    # we can check if a merchant has one or more bank acounts, emails, pm, etc.. Otherwise we have to
    # make a separate merchant select in every other method.
    def put_merchants_into_iso_group
      if @merchants
        @logger.info("Puting merchants into ISO groups")
        @merchants.each do |merchant|
          unless (merchant.emp_agent.empty? || merchant.emp_agent.first.emp_iso.empty?)
            sg = find_sugarcrm_object('security_group','name', merchant.emp_agent.first.emp_iso.first.name)          
            @logger.info("Puting merchant #{merchant.name} into ISO group")
            
            if sg
              merchant.associate! sg
              put_email_objects_into_iso_group(sg, merchant.sf_id)
              put_payment_methods_objects_into_iso_group(sg, merchant.sf_id)
            end
            
            bank  = find_sugarcrm_object('settlement_bank_account', 'sf_merchant', merchant.sf_id)
            if (bank)
              @logger.info("Puting Bank Account for #{merchant.name} into ISO group")
               put_bank_accounts_into_iso_group(bank, sg)
            end
          end
        end
      end
    end
    
    def put_bank_accounts_into_iso_group(banks, sg)
      if banks.is_a?(Array)
        banks.each do |bank|
          bank.associate! sg
        end
      else
        banks.associate! sg
      end
    end
    
    def put_email_objects_into_iso_group(sg, merchant_id)
      @logger.info("Puting Emails into ISO group")
      email_id = find_email_id(merchant_id)
      if email_id
        email = find_sugarcrm_object('email', 'sf_id', email_id)
        if email
          if email.is_a?(Array)
            email.each do |e|
              e.associate! sg
            end
          else
            email.associate! sg
          end
        end
      end
    end
    
    def put_payment_methods_objects_into_iso_group(sg, merchant_id)
      @logger.info("Puting Payment Methods into ISO group")
      payment_method_id = find_payment_method_id(merchant_id)
      if payment_method_id
        payment_method = find_sugarcrm_object('payment_method', 'sf_id', payment_method_id)
        if payment_method
          if payment_method.is_a?(Array)
            payment_method.each do |pm|
              pm.associate! sg
            end
          else
            payment_method.associate! sg
          end
        end
      end
    end
    
    # Returns the SugarCRM module namespace
    # @param [String] type type of the module object
    def get_sugarcrm_module_type(type)
      modules = {
        "iso"                     => SugarCRM::EmpIso,
        "agent"                   => SugarCRM::EmpAgent,
        "merchant"                => SugarCRM::EmpMerchant,
        "payment_method"          => SugarCRM::EmpPaymentmethod,
        "settlement_bank_account" => SugarCRM::EmpSettlementBankAccount,
        "security_group"          => SugarCRM::SecurityGroup,
        "email"                   => SugarCRM::EmpEmail
      }
      modules[type]
    end

    # Find a SugarCRM object
    #
    # @param [String] type type of the module object
    # @param [String] attribute name of the attribute to search by
    # @param [String] search_string string used in WHERE clause
    #   find_sugarcrm_object('emp_ISO', 'sf_id', 'a073000000SSTEYAA5') # => #<SugarCRM::Namespace0::EmpIso ... >
    def find_sugarcrm_object(type, attribute, search_string)
        module_type = get_sugarcrm_module_type(type)._module.name
        SugarCRM.connection.get_entry_list(module_type, "#{module_type.downcase}.#{attribute} = '#{search_string}'")
    end

  end
end