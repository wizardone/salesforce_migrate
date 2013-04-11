$LOAD_PATH.unshift File.dirname(__FILE__)

module SalesforceMigration
  
  class Mailer
    
    def initialize(options)
      credentials = YAML.load_file(options[:config_file])

      @template = "Welcome to Emerchantpay Agent Portal"
      @logger = SalesforceMigration::Runner::create_logger
      
      #Ugly way to fix the bug with user_hash update
      #We set up a connection and update it manually.update_attributes does not work.
      #The issue is forwarded to sugarcrm gem crew
      ActiveRecord::Base.establish_connection(
        :adapter  => credentials['db_type'],
        :host     => "localhost",
        :username => credentials['db_user'],
        :password => credentials['db_password'],
        :database => credentials['db_database']
      )
      
      @logger.info("Starting the mailer")
      start
      @logger.info("Mailer finished")
    end
    
    private
    
    #Search the agent portal database for all users, who are inactive
    #This is the script, that activates them
    def start
      inactive_users = SugarCRM::User.find_all_by_status('Inactive')

      if inactive_users
        inactive_users.each do |user|
          @logger.info("Sending email to #{user.last_name}")

          plain_password = generate_password
          hash_password = Digest::MD5.hexdigest plain_password
          
          sm = send_mail(user.email1, user.user_name, plain_password)
          if sm
            query = "UPDATE users SET user_hash='#{hash_password}', status='Active' WHERE id='#{user.id}'"
            ActiveRecord::Base.connection.execute(query);

            @logger.info("Updated user #{user.last_name} status to active")
          end
        end
      end
    end
    
    #Send the welcoming email to the user
    #We need the welcoming text
    #@param [String] the email address
    def send_mail(email, username, password)
      mail = Mail.new do
        from    'agent_portal@emerchantpay.com'
        to      email
        subject 'Welcome to Emerchantpay Agent Portal'
        body    "Your username is #{username} and your password is #{password}"
      end
      mail.delivery_method :smtp, {:address        => "emp-ldn-exch01.emp.internal.com",
                                   :port           => 25,
                                   :domain         => "emp.internal.com",
                                   :authentication => nil,
                                   :enable_starttls_auto => true}

      if mail.deliver!
        true
      else
        @logger.error("Email for user #{last_name} failed!")  
      end
    end
    
    # Generates the plain text password that is going to be
    # send to the user in the email
    # ActiveSupport::SecureRandom is deprecated in Rails  > 3.1
    def generate_password
      str = SecureRandom.hex(6)
      str
    end
    
    def create_template
      template = "this is bla-bla-bla-bla"
      template
    end
  end
end