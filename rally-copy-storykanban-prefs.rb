# Copyright 2002-2013 Rally Software Development Corp. All Rights Reserved.

require 'rally_api'
require 'csv'
require 'json'
require 'logger'
require 'open-uri'
require './multi_io.rb'

$my_base_url       = "https://rally1.rallydev.com/slm"

$my_username       = "user@company.com"
$my_password       = "password"
$my_workspace      = "My Workspace"
$my_project        = "My Project"
$wsapi_version     = "v2.0"

$input_filename    = "rally-copy-kanban-prefs.csv"


# Load (and maybe override with) my personal/private variables from a file...
my_vars= File.dirname(__FILE__) + "/my_vars.rb"
if FileTest.exist?( my_vars ) then require my_vars end

if $my_delim == nil then $my_delim = "," end

def make_prefs_query_url(project_oid, app_oid)

  query_str = "query=((AppId = #{app_oid}) AND (Project = \"/project/#{project_oid}\"))&fetch=ObjectID,AppId,Name,Value,CreationDate,Project,User,Workspace&project=/project/#{project_oid}"
  prefs_query_params  = "start=1&pagesize=200"
  prefs_query_url     = "#{$my_base_url}/webservice/#{$wsapi_version}/Preference?#{prefs_query_params}&#{query_str}"
  prefs_query_encoded = URI::encode(prefs_query_url)
  return prefs_query_encoded

end

def get_kanban_prefs(project_oid, app_oid)

  prefs_query_url = make_prefs_query_url(project_oid, app_oid)
  args = {:method => :get}
  response = @rally_json_connection.send_request(prefs_query_url, args)
  return response["QueryResult"]

end

def make_pref_create_url(project_oid)
  create_url = "#{$my_base_url}/webservice/#{$wsapi_version}/Preference/create?fetch=true&includePermissions=true&project=/project/#{project_oid}"
  create_url_encoded = URI::encode(create_url)
  return create_url_encoded
end

def make_pref_update_url(project_oid, preference_oid)
  update_url = "#{$my_base_url}/webservice/#{$wsapi_version}/Preference/#{preference_oid}?fetch=true&includePermissions=true&project=/project/#{project_oid}"
  update_url_encoded = URI::encode(update_url)
  return update_url_encoded
end

def get_errors(wsapi_response, operation_type)

  case operation_type
  when :create
    result_type = "CreateResult"
  when :update
    result_type = "OperationResult"
  end

  result = wsapi_response[result_type]
  errors = result["Errors"]
  return errors
end

def copy_prefs_to_target(target_project_oid, app_oid, source_prefs_hash)

  target_prefs_hash = get_prefs_hash(target_project_oid, app_oid)

  source_prefs_hash.each_pair do | this_pref_name, this_pref_info |

    # Policy Pref doesn't already exist, create it
    if !target_prefs_hash.has_key?(this_pref_name) then

      create_pref_value = this_pref_info["Value"]

      pref_create_fields = {
        "Preference" => {
          "Name"     => this_pref_name,
          "Value"    => create_pref_value,
          "Project"  => "/project/#{target_project_oid}",
          "AppID"    => app_oid
        }
      }

      args = {:method => :put}
      args[:payload] = pref_create_fields

      prefs_create_url = make_pref_create_url(target_project_oid)

      # @rally_json_connection does a to_json on object to convert
      # payload object to JSON: {""Preference"":{""Name"":""ScheduleStateCustom StatePolicy"",""Value"":""Custom State Exit Policy"",""Project"":""/project/4625248927"",""AppId"":9552890650}}
      response = @rally_json_connection.send_request(prefs_create_url, args)
      errors = get_errors(response, :create)

      if errors.length > 0 then
        @logger.error errors
      else
        @logger.info "Target Kanban policy #{this_pref_name} created: #{create_pref_value}"
      end

    else # Policy Pref DOES exist, update it

      update_pref_value = this_pref_info["Value"]

      target_pref_info = target_prefs_hash[this_pref_name]
      target_pref_oid = target_pref_info["ObjectID"]
      target_pref_value = target_pref_info["Value"]

      if !target_pref_value.eql?(update_pref_value) then
        pref_update_fields = {
          "Preference" => {
            "Value" => update_pref_value
          }
        }

        args = {:method => :post}
        args[:payload] = pref_update_fields

        prefs_update_url = make_pref_update_url(target_project_oid, target_pref_oid)

        # @rally_json_connection does a to_json on object to convert
        # payload object to JSON: {""Preference"":{""Value"":""Custom State Exit Policy""}}
        response = @rally_json_connection.send_request(prefs_update_url, args)
        errors = get_errors(response, :update)
        if errors.length > 0 then
          @logger.error errors
        else
          @logger.info "Target Kanban policy #{this_pref_name} updated: #{update_pref_value}"
        end
      else # Pref/Policy is already equal to this value
        @logger.info "Source/Target Policies are already the same. No copy/update is needed."
      end
    end
  end
end

def get_prefs_hash(project_oid, app_oid)

  prefs_response = get_kanban_prefs(project_oid, app_oid)
  number_results = prefs_response["TotalResultCount"]
  @logger.info "Found #{number_results} Preferences for App ObjectID: #{app_oid}."

  this_prefs_hash = {}
  if number_results > 0 then
    prefs_results = prefs_response["Results"]
    prefs_results.each do | this_pref |
      pref_name = this_pref["Name"]
      if pref_name.include?("Policy") then
        @logger.info "Read Policy for Column: #{this_pref['Name']}"
        @logger.info "Policy Value: #{this_pref['Value']}"
        @logger.info "Policy ObjectID: #{this_pref['ObjectID']}"
        this_prefs_info = {
          "Value" => this_pref["Value"],
          "ObjectID" => this_pref["ObjectID"]
        }
        this_prefs_hash[pref_name] = this_prefs_info
      end
    end
  end

  return this_prefs_hash
end

def clean_input(input_field)
  if !input_field.nil? then
    cleaned_field = input_field.strip
  else
    cleaned_field = ''
  end
  return cleaned_field
end

def copy_prefs(header, row)

  app_oid                         = clean_input(row[header[0]])
  source_project_name             = clean_input(row[header[1]])
  source_project_oid              = clean_input(row[header[2]])
  target_project_name             = clean_input(row[header[3]])
  target_project_oid              = clean_input(row[header[4]])

  source_prefs_hash               = get_prefs_hash(source_project_oid, app_oid)
  copy_prefs_to_target(target_project_oid, app_oid, source_prefs_hash)

end

begin

  #==================== Making a connection to Rally ====================
  config                  = {:base_url => $my_base_url}
  config[:username]       = $my_username
  config[:password]       = $my_password
  config[:headers]        = $my_headers #from RallyAPI::CustomHttpHeader.new()
  config[:workspace]      = $my_workspace
  config[:project]        = $my_project
  config[:version]        = $wsapi_version

  # Instantiate Logger
  log_file = File.open("rally-copy-storykanban-prefs.log", "a")
  log_file.sync = true
  @logger = Logger.new MultiIO.new(STDOUT, log_file)
  @logger.level = Logger::INFO #DEBUG | INFO | WARNING | FATAL

  @logger.info "Connecting to #{$my_base_url} as UserID: #{$my_username}"
  @rally                 = RallyAPI::RallyRestJson.new(config)
  @rally_json_connection = @rally.rally_connection

  @logger.info "Reading Kanban settings from input file: #{$input_filename}"

  csv_options = {
    :col_sep => $my_delim,
    :encoding => 'windows-1251:utf-8'
  }

  input  = CSV.read($input_filename, csv_options)

  header = input.first #ignores first line
  header_row = CSV::Row

  rows   = []
  (1...input.size).each { |i| rows << CSV::Row.new(header, input[i]) }

  rows.each do | row |
    copy_prefs(header, row)
  end
end