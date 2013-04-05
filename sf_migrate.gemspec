Gem::Specification.new do |s|
  s.name        = "sf_migrate"
  s.version     = "1.0.2"
  s.description = "SalesForce to SugarCRM migration tool"
  s.summary     = "Makes a bridge between Salesforce and SugarCRM"

  s.authors = ["Dimitar Kostov" "Stefan Slaveykov"]
  s.email   = ["stefan@emerchantpay.com"]

  s.files = [
    "README.md",
    "Gemfile",
    "bin/sf_migrate",
    "lib/fields.rb",
    "lib/export.rb",
    "lib/import.rb",
    "lib/mailer.rb",
    "lib/sf_migrate.rb",
    "config/credentials.yaml"
  ]

  s.executables = "sf_migrate"

  s.add_dependency "sugarcrm_emp",   "~> 0.10.1"
  s.add_dependency "databasedotcom_emp", "~> 1.3.1"
  s.add_dependency "activesupport",  "~> 3.2.6"
  s.add_dependency "mail",  "~> 2.5.3"
  s.add_dependency "roo",  "~> 1.10.2"
end
