# frozen_string_literal: true

require 'json'
require 'csv'
require 'fileutils'
require 'dotenv/load'
require 'rest-client'
require 'base64'

@debug = ENV['DEBUG'] == 'true'

ASSEMBLA_SPACE = ENV['ASSEMBLA_SPACE'].freeze

ASSEMBLA_API_HOST = ENV['ASSEMBLA_API_HOST'].freeze
ASSEMBLA_API_KEY = ENV['ASSEMBLA_API_KEY'].freeze
ASSEMBLA_API_SECRET = ENV['ASSEMBLA_API_SECRET'].freeze
ASSEMBLA_HEADERS = { 'X-Api-Key': ASSEMBLA_API_KEY, 'X-Api-Secret': ASSEMBLA_API_SECRET }.freeze

ASSEMBLA_SKIP_ASSOCIATIONS = (ENV['ASSEMBLA_SKIP_ASSOCIATIONS'] || '').split(',').push('unknown')

ASSEMBLA_TYPES_IN_SUMMARY = (ENV['ASSEMBLA_TYPES_IN_SUMMARY'] || '').split(',')

JIRA_API_HOST = ENV['JIRA_API_HOST'].freeze
JIRA_API_ADMIN_USER = ENV['JIRA_API_ADMIN_USERNAME'].freeze
JIRA_API_UNKNOWN_USER = ENV['JIRA_API_UNKNOWN_USER'].freeze

JIRA_API_IMAGES_THUMBNAIL = (ENV['JIRA_API_IMAGES_THUMBNAIL'] || 'description:false,comments:true').freeze

# Jira project type us 'scrum' by default
JIRA_API_PROJECT_TYPE = (ENV['JIRA_API_PROJECT_TYPE'] || 'scrum').freeze

JIRA_HEADERS = { 'Authorization': "Basic #{Base64.encode64(JIRA_API_ADMIN_USER + ':' + ENV['JIRA_API_ADMIN_PASSWORD'])}", 'Content-Type': 'application/json', 'Accept': 'application/json' }

URL_JIRA_PROJECTS = "#{JIRA_API_HOST}/project"
URL_JIRA_ISSUE_TYPES = "#{JIRA_API_HOST}/issuetype"
URL_JIRA_PRIORITIES = "#{JIRA_API_HOST}/priority"
URL_JIRA_RESOLUTIONS = "#{JIRA_API_HOST}/resolution"
URL_JIRA_ROLES = "#{JIRA_API_HOST}/role"
URL_JIRA_STATUSES = "#{JIRA_API_HOST}/status"
URL_JIRA_FIELDS = "#{JIRA_API_HOST}/field"
URL_JIRA_ISSUES = "#{JIRA_API_HOST}/issue"
URL_JIRA_ISSUELINK_TYPES = "#{JIRA_API_HOST}/issueLinkType"
URL_JIRA_ISSUELINKS = "#{JIRA_API_HOST}/issueLink"
URL_JIRA_FILTERS = "#{JIRA_API_HOST}/filter"

OUTPUT_DIR = 'data'
OUTPUT_DIR_ASSEMBLA = "#{OUTPUT_DIR}/assembla"
OUTPUT_DIR_JIRA = "#{OUTPUT_DIR}/jira"

# The following custom fields MUST be defined AND associated with the proper screens
CUSTOM_FIELD_NAMES = %w(Assembla-Id Assembla-Milestone Assembla-Theme Assembla-Status Assembla-Reporter Assembla-Assignee Assembla-Completed Epic\ Name Rank Story\ Points)

JIRA_AGILE_HOST = ENV['JIRA_AGILE_HOST']
URL_JIRA_BOARDS = "#{JIRA_AGILE_HOST}/board"
URL_JIRA_SPRINTS = "#{JIRA_AGILE_HOST}/sprint"

def get_tickets_created_on
  env = ENV['TICKETS_CREATED_ON']
  return nil unless env
  begin
    tickets_created_on = Date.strptime(env, "%Y-%m-%d")
  rescue
    goodbye("File '.env' contains an invalid date for ENV['TICKETS_CREATED_ON']='#{env}'")
  end
  tickets_created_on
end

def item_newer_than?(item, date)
  item_date = item['created_on'] || item['created_at']
  goodbye("Item created date cannot be found") unless item_date
  DateTime.parse(item_date) > date
end

# Assuming that the user name is the same as the user password
def headers_user_login(user_login)
  { 'Authorization': "Basic #{Base64.encode64(user_login + ':' + user_login)}", 'Content-Type': 'application/json' }
end

def date_format_yyyy_mm_dd(dt)
  return dt unless dt.is_a?(String) && dt.length.positive?
  begin
    date = DateTime.parse(dt)
  rescue
    return dt
  end
  year = date.year
  month = "%02d" % date.month
  day = "%02d" % date.day
  "#{year}-#{month}-#{day}"
end

def date_time(dt)
  return dt unless dt.is_a?(String) && dt.length.positive?
  begin
    date = DateTime.parse(dt)
  rescue
    return dt
  end
  day = "%02d" % date.day
  month = %w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)[date.month-1]
  year = date.year
  hour = "%02d" % date.hour
  minute = "%02d" % date.minute
  "#{day} #{month} #{year} #{hour}:#{minute}"
end

def ticket_to_s(ticket)
  ticket.delete_if { |k| k =~ /summary|description/ }.inspect
end

def build_counter(opts)
  opts[:counter] ? "[#{opts[:counter]}/#{opts[:total]}] " : ''
end

def http_request(url, opts = {})
  response = ''
  counter = build_counter(opts)
  begin
    response = RestClient::Request.execute(method: :get, url: url, headers: ASSEMBLA_HEADERS)
    count = get_response_count(response)
    puts "#{counter}GET #{url} => OK (#{count})"
  rescue => e
    if e.class == RestClient::NotFound && e.response.match?(/Tool not found/i)
      puts "#{counter}GET #{url} => OK (0)"
    else
      message = "#{counter}GET #{url} => NOK (#{e.message})"
      if opts[:continue_onerror]
        puts message
      else
        goodbye(message)
      end
    end
  end
  response
end

def get_response_count(response)
  return 0 if response.nil? || !response.is_a?(String) || response.length.zero?
  begin
    json = JSON.parse(response)
    return 0 unless json.is_a?(Array)
     return json.length
  rescue
    return 0
  end
end

def get_space(name)
  response = http_request("#{ASSEMBLA_API_HOST}/spaces")
  json = JSON.parse(response.body)
  space = json.find { |s| s['name'] == name }
  unless space
    goodbye("Couldn't find space with name = '#{name}'")
  end
  space
end

def get_items(items, space)
  items.each do |item|
    url = "#{ASSEMBLA_API_HOST}/spaces/#{space['id']}/#{item[:name]}"
    url += "?#{item[:q]}" if item[:q]
    per_page = item[:q] =~ /per_page/
    page = 1
    in_progress = true
    item[:results] = []
    while in_progress
      full_url = url
      full_url += "&page=#{page}" if per_page
      response = http_request(full_url)
      count = get_response_count(response)
      if count.positive?
        JSON.parse(response).each do |rec|
          item[:results] << rec
        end
        per_page ? page += 1 : in_progress = false
      else
        in_progress = false
      end
    end
  end
  items
end

def create_csv_files(space, items)
  items = [items] unless items.is_a?(Array)
  items.each do |item|
    create_csv_file(space, item)
  end
  puts "#{space['name']} #{items.map{|item| item[:name]}.to_json} => done!"
end

def create_csv_file(space, item)
  dirname = get_output_dirname(space, 'assembla')
  filename = "#{dirname}/#{normalize_name(item[:name])}.csv"
  write_csv_file(filename, item[:results])
end

def export_items(list)
  space = get_space(ASSEMBLA_SPACE)
  items = get_items(list, space)
  create_csv_files(space, items)
end

def write_csv_file(filename, results)
  puts filename
  CSV.open(filename, 'wb') do |csv|
    # Scan whole file to collect all possible field names so that
    # the list of columns is complete.
    fields = []
    results.each do |result|
      result.keys.each do |field|
        fields << field unless fields.include?(field)
      end
    end
    csv << fields
    results.each do |result|
      row = []
      fields.each do |field|
        row.push(result[field])
      end
      csv << row
    end
  end
end

def get_output_dirname(space, dir = nil)
  dirname = "#{OUTPUT_DIR}/#{dir ? (normalize_name(dir) + '/' ) : ''}#{normalize_name(space['name'])}"
  FileUtils.mkdir_p(dirname) unless File.directory?(dirname)
  dirname
end

def normalize_name(s)
  s.downcase.tr(' /_', '-')
end

def csv_to_array(pathname)
  csv = CSV::parse(File.open(pathname, 'r') { |f| f.read } )
  fields = csv.shift
  fields = fields.map { |f| f.downcase.tr(' ', '_') }
  csv.map { |record| Hash[*fields.zip(record).flatten] }
end

def jira_check_unknown_user(b)
  puts "\nUnknown user:" if b
  if JIRA_API_UNKNOWN_USER && JIRA_API_UNKNOWN_USER.length
    user = jira_get_user(JIRA_API_UNKNOWN_USER)
    if user
      goodbye("Please activate Jira unknown user '#{JIRA_API_UNKNOWN_USER}'") unless user['active']
    else
      goodbye("Cannot find Jira unknown user '#{JIRA_API_UNKNOWN_USER}', make sure that has been created and enabled")
    end
  else
    goodbye("Please define 'JIRA_API_UNKNOWN_USER' in the .env file")
  end
end

def jira_build_project_key(project_name)
  # Max. length = 10
  key = project_name.split(' ').map { |w| w[0].upcase }.join
  key = project_name.upcase if key.length == 1
  key = key[0..9] if key.length > 10
  key
end

# Create project and scrum/kanban board
# POST /rest/api/2/project
# {
#   key: project_key,
#   name: project_name,
#   projectTypeKey: 'software',
#   description: project_description,
#   projectTemplateKey: "com.pyxis.greenhopper.jira:gh-#{type}-template",
#   lead: username
# }
#
# where '#{type}' must be either 'scrum' or 'kanban'
#
def jira_create_project(project_name, project_type)
  goodbye("Invalid project type=#{project_type}, must be 'scrum' or 'kanban'") unless %w(scrum kanban).include?(project_type)
  result = nil
  key = jira_build_project_key(project_name)
  payload = {
    key: key,
    name: project_name,
    projectTypeKey: 'software',
    description: "Description of project '#{project_name}'",
    projectTemplateKey: "com.pyxis.greenhopper.jira:gh-#{project_type}-template",
    lead: JIRA_API_ADMIN_USER
  }.to_json
  begin
    response = RestClient::Request.execute(method: :post, url: URL_JIRA_PROJECTS, payload: payload, headers: JIRA_HEADERS)
    result = JSON.parse(response.body)
    puts "POST #{URL_JIRA_PROJECTS} name='#{project_name}', key='#{key}' => OK"
  rescue RestClient::ExceptionWithResponse => e
    error = JSON.parse(e.response)
    message = error['errors'].map { |k, v| "#{k}: #{v}" }.join(' | ')
    puts "POST #{URL_JIRA_PROJECTS} name='#{project_name}', key='#{key}' => NOK (#{message})"
  rescue => e
    puts "POST #{URL_JIRA_PROJECTS} name='#{project_name}', key='#{key}' => NOK (#{e.message})"
  end
  result
end

def jira_get_projects
  result = nil
  begin
    response = RestClient::Request.execute(method: :get, url: URL_JIRA_PROJECTS, headers: JIRA_HEADERS)
    result = JSON.parse(response)
    if result
      result.each do |r|
        r.delete_if { |k, _| k.to_s =~ /expand|self|avatarurls/i }
      end
      puts "GET #{URL_JIRA_PROJECTS} => OK (#{result.length})"
    end
  rescue => e
    puts "GET #{URL_JIRA_PROJECTS} => NOK (#{e.message})"
  end
  result
end

def jira_get_project_by_name(name)
  result = nil
  begin
    response = RestClient::Request.execute(method: :get, url: URL_JIRA_PROJECTS, headers: JIRA_HEADERS)
    body = JSON.parse(response.body)
    result = body.detect { |h| h['name'] == name }
    if result
      result.delete_if { |k, _| k =~ /expand|self|avatarurls/i }
      puts "GET #{URL_JIRA_PROJECTS} name='#{name}' => OK"
    end
  rescue => e
    puts "GET #{URL_JIRA_PROJECTS} name='#{name}' => NOK (#{e.message})"
  end
  result
end

def jira_get_priorities
  result = []
  begin
    response = RestClient::Request.execute(method: :get, url: URL_JIRA_PRIORITIES, headers: JIRA_HEADERS)
    result = JSON.parse(response.body)
    if result
      result.each do |r|
        r.delete_if { |k, _| k =~ /self|statuscolor|iconurl/i }
      end
      puts "GET #{URL_JIRA_PRIORITIES} => (#{result.length})"
    end
  rescue => e
    puts "GET #{URL_JIRA_PRIORITIES} => NOK (#{e.message})"
  end
  result
end

def jira_get_resolutions
  result = []
  begin
    response = RestClient::Request.execute(method: :get, url: URL_JIRA_RESOLUTIONS, headers: JIRA_HEADERS)
    result = JSON.parse(response.body)
    if result
      result.each do |r|
        r.delete_if { |k, _| k =~ /self/i }
      end
      puts "GET #{URL_JIRA_RESOLUTIONS} => (#{result.length})"
    end
  rescue => e
    puts "GET #{URL_JIRA_RESOLUTIONS} => NOK (#{e.message})"
  end
  result
end

def jira_get_roles
  result = []
  begin
    response = RestClient::Request.execute(method: :get, url: URL_JIRA_ROLES, headers: JIRA_HEADERS)
    result = JSON.parse(response.body)
    if result
      result.each do |r|
        r.delete_if { |k, _| k =~ /self/i }
      end
      puts "GET #{URL_JIRA_ROLES} => (#{result.length})"
    end
  rescue => e
    puts "GET #{URL_JIRA_ROLES} => NOK (#{e.message})"
  end
  result
end

def jira_get_statuses
  result = []
  begin
    response = RestClient::Request.execute(method: :get, url: URL_JIRA_STATUSES, headers: JIRA_HEADERS)
    result = JSON.parse(response.body)
    if result
      result.each do |r|
        r.delete_if { |k, _| k =~ /self|iconurl|statuscategory/i }
      end
      puts "GET #{URL_JIRA_STATUSES} => (#{result.length})"
    end
  rescue => e
    puts "GET #{URL_JIRA_STATUSES} => NOK (#{e.message})"
  end
  result
end

def jira_get_issue_types
  result = nil
  begin
    response = RestClient::Request.execute(method: :get, url: URL_JIRA_ISSUE_TYPES, headers: JIRA_HEADERS)
    result = JSON.parse(response)
    if result
      result.each do |r|
        r.delete_if { |k, _| k.to_s =~ /self|iconurl|avatarid/i }
      end
      puts "GET #{URL_JIRA_ISSUE_TYPES} => OK (#{result.length})"
    end
  rescue => e
    puts "GET #{URL_JIRA_ISSUE_TYPES} => NOK (#{e.message})"
  end
  result
end

def jira_get_issuelink_types
  result = nil
  begin
    response = RestClient::Request.execute(method: :get, url: URL_JIRA_ISSUELINK_TYPES, headers: JIRA_HEADERS)
    result = JSON.parse(response)
    result = result['issueLinkTypes']
    if result
      result.each do |r|
        r.delete_if { |k, _| k.to_s =~ /self/i }
      end
      puts "GET #{URL_JIRA_ISSUELINK_TYPES} => OK (#{result.length})"
    end
  rescue => e
    puts "GET #{URL_JIRA_ISSUELINK_TYPES} => NOK (#{e.message})"
  end
  result
end

def jira_create_custom_field(name, description, type)
  result = nil
  payload = {
    name: name,
    description: description,
    type: type
  }.to_json
  begin
    response = RestClient::Request.execute(method: :post, url: URL_JIRA_FIELDS, payload: payload, headers: JIRA_HEADERS)
    result = JSON.parse(response.body)
    puts "POST #{URL_JIRA_FIELDS} name='#{name}' => OK (#{result['id']})"
  rescue RestClient::ExceptionWithResponse => e
    error = JSON.parse(e.response)
    message = error['errors'].map { |k, v| "#{k}: #{v}" }.join(' | ')
    puts "POST #{URL_JIRA_FIELDS} name='#{name}' => NOK (#{message})"
  rescue => e
    puts "POST #{URL_JIRA_FIELDS} name='#{name}' => NOK (#{e.message})"
  end
  result
end

def jira_get_fields
  result = []
  begin
    response = RestClient::Request.execute(method: :get, url: URL_JIRA_FIELDS, headers: JIRA_HEADERS)
    result = JSON.parse(response.body)
    puts "GET #{URL_JIRA_FIELDS} => (#{result.length})"
  rescue => e
    puts "GET #{URL_JIRA_FIELDS} => NOK (#{e.message})"
  end
  result
end

def jira_create_user(user)
  result = nil
  url = "#{JIRA_API_HOST}/user"
  username = user['login']
  email = user['email']
  if email.nil? || email.empty?
    email = "#{username}@example.org"
  end
  payload = {
    name: username,
    password: username,
    # TODO: Make the following configurable and not hard-coded.
    emailAddress: email,
    displayName: user['name'],
  }.to_json
  begin
    response = RestClient::Request.execute(method: :post, url: url, payload: payload, headers: JIRA_HEADERS)
    body = JSON.parse(response.body)
    body.delete_if { |k, _| k =~ /self|avatarurls|timezone|locale|groups|applicationroles|expand/i }
    puts "POST #{url} username='#{username}' => OK (#{body.to_json})"
    result = body
  rescue RestClient::ExceptionWithResponse => e
    error = JSON.parse(e.response)
    message = error['errors'].map { |k, v| "#{k}: #{v}" }.join(' | ')
    goodbye("POST #{url} username='#{username}' => NOK (#{message})")
  rescue => e
    goodbye("POST #{url} username='#{username}' => NOK (#{e.message})")
  end
  result
end

def jira_get_user(username)
  result = nil
  url = "#{JIRA_API_HOST}/user?username=#{username}"
  begin
    response = RestClient::Request.execute(method: :get, url: url, headers: JIRA_HEADERS)
    body = JSON.parse(response.body)
    body.delete_if { |k, _| k =~ /self|avatarurls|timezone|locale|groups|applicationroles|expand/i }
    puts "GET #{url} => OK (#{body.to_json})"
    result = body
  rescue => e
    if e.class == RestClient::NotFound && JSON.parse(e.response)['errorMessages'][0] =~ /does not exist/
      puts "GET #{url} => NOK (does not exist)"
    else
      goodbye("GET #{url} => NOK (#{e.message})")
    end
  end
  result
end

def jira_get_board_by_project_name(project_name)
  result = nil
  url = URL_JIRA_BOARDS
  key = jira_build_project_key(project_name)
  begin
    response = RestClient::Request.execute(method: :get, url: url, headers: JIRA_HEADERS)
    body = JSON.parse(response.body)
    # max_results = body['maxResults'].to_i
    # start_at = body['startAt'].to_i
    # is_last = body['isLast']
    values = body['values']
    if values
      result = values.detect { |h| h['name'].match(/^#{key}/) }
      if result
        result.delete_if { |k, _| k =~ /self/i }
        puts "GET #{url} name='#{project_name}', key='#{key}' => FOUND"
      else
        puts "GET #{url} name='#{project_name}', key='#{key}' => NOT FOUND"
      end
    end
  rescue => e
    puts "GET #{url} name='#{project_name}', key='#{key}' => NOK (#{e.message})"
  end
  result
end

def goodbye(message)
  puts "\nGOODBYE: #{message}"
  exit
end

def warning(message)
  puts "\nWARNING: #{message}"
end

# Take original Assembla markdown and reformat it to the relevant Jira markdown.
#
# h1. TITLE => same
# h2. TITLE => same
# *bold* => same
# _italic_ => same
# @inline code@ => {{inline code}} (monospaced)
#
# Bullet list => same
# Numbered list => same
# Numbered - Bullet list => same?
#
# [[image:IMAGE]] => !name(IMAGE)|thumbnail!
# [[image:IMAGE|text]] => !name(IMAGE)|thumbnail!
#
# [[url:URL|TEXT]] => [TEXT|URL]
# [[url:URL]] => [URL|URL]
#
# @login => [~login]
#
# Code snippet => ignore
#
# Wiki links => ignore
#
# [[ticket:NUMBER]] => ignore
#
# [[user:NAME]] => ignore
# [[user:NAME|TEXT]] => ignore

@cache_markdown_names = {}

def markdown_name(name, list_of_logins)
  name = name[1..-1].sub(/@.*$/, '').strip
  return @cache_markdown_names[name] if @cache_markdown_names[name]
  ok = list_of_logins[name]
  result = ok ? "[~#{name}]" : "@#{name}"
  puts "Reformat markdown name='#{name}' => #{ok ? '' : 'N'}OK" unless ok
  @cache_markdown_names[name] = result
end

@content_types_thumbnail = {}

JIRA_API_IMAGES_THUMBNAIL.split(',').each do |item|
  content_type, thumbnail = item.split(':')
  @content_types_thumbnail[content_type] = thumbnail !~ /false|no|0/i
  # puts "@content_types_thumbnail['#{content_type}'] = #{@content_types_thumbnail[content_type]}"
end

def markdown_image(image, list_of_images, content_type)
  _, id, text = image[2...-2].split(/:|\|/)
  name = list_of_images[id]
  if name
    result = "!#{name}#{@content_types_thumbnail[content_type] ? '|thumbnail' : ''}!"
  else
    result = image
    puts "Reformat markdown image='#{image}', id='#{id}', text='#{text}' => NOK"
  end
  result
end

#
# Reformat Assembla markdown to Jira markdown
#
# [[image:IMAGE]] => !name(IMAGE)|thumbnail!
# [[image:IMAGE|text]] => !name(IMAGE)|thumbnail!
# @login => [~login]
# @inline code@ => {{inline code}} (monospaced)
# [[url:URL|TEXT]] => [TEXT|URL]
# [[url:URL]] => [URL|URL]
# <pre><code> code-snippet </code></pre> => {code:java} code-snippet {code}
#
def reformat_markdown(content, list_of_logins, list_of_images, content_type)
  return content if content.nil? || content.length.zero?
  lines = content.split("\n")
  markdown = []
  lines.each do |line|
    markdown << line.
                gsub(/<pre><code>/i,'{code:java}').
                gsub(/<\/code><\/pre>/i,'{code}').
                gsub(/\[\[url:(.*)\|(.*)\]\]/i, '[\2|\1]').
                gsub(/\[\[url:(.*)\]\]/i, '[\1|\1]').
                gsub(/@([^@]*)@( |$)/, '{{\1}}\2').
                gsub(/@([a-z.-_]*)/i) { |name| markdown_name(name, list_of_logins) }.
                gsub(/\[\[image:(.*)(\|(.*))?\]\]/i) { |image| markdown_image(image, list_of_images, content_type) }
  end
  markdown.join("\n")
end

def rest_client_exception(e, method, url, payload = {})
  message = 'Unknown message'
  begin
    err = JSON.parse(e.response)
  rescue
    err = {}
  end
  if err['errors'] && !err['errors'].empty?
    message = err['errors'].map { |k, v| "#{k}: #{v}" }.join(' | ')
  elsif err['errorMessages'] && !err['errorMessages'].empty?
    message = err['errorMessages'].join(' | ')
  elsif err['error']
    message = err['error']
    if err['error_description']
      message += ": #{err['error_description']}"
    end
  elsif err['status-code']
    message = "Status code: #{err['status-code']}"
  elsif e.class == RestClient::NotFound
    message = '404 Not Found'
  else
    message = err.inspect[0...250]
  end
  puts "#{method} #{url}#{payload.empty? ? '' : ' ' + payload.inspect} => NOK (#{message})"
end
