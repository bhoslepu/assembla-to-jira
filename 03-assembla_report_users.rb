# frozen_string_literal: true

#
# Generates a summary report for users listed in order of most activity by analyzing all of the assembla dump csv files.
#
# count
# user: id, login, name, picture, email, organization, phone
# documents: created_by
# milestones: created_by
# ticket-attachments: created_by
# ticket-comments: user_id
# tickets: assigned_to_id, reporter_id
# user-roles: user_id, invited_by_id
# wiki-pages: user_id
#
# count | id | login | name | picture | email | organization | phone | documents:created_by | milestones:created_by |
# ticket-attachments:created_by | ticket-comments:user_id | tickets:assigned_to_id | tickets:reporter_id |
# user-roles:user_id | user-roles:invited_by_id | wiki-pages:user_id

load './lib/common.rb'

@users = []
@users_index = {}
@num_unknowns = 0

FILES = [
  { name: 'documents', fields: %w[created_by] },
  { name: 'milestones', fields: %w[created_by] },
  { name: 'ticket-attachments', fields: %w[created_by] },
  { name: 'ticket-comments', fields: %w[user_id] },
  { name: 'tickets', fields: %w[assigned_to_id reporter_id] },
  { name: 'user-roles', fields: %w[user_id invited_by_id] },
  { name: 'wiki-pages', fields: %w[user_id] }
].freeze

def create_user_index(user, space)
  # Some sanity checks just in case
  goodbye('create_user_index() => NOK (user is undefined)') unless user
  goodbye('create_user_index() => NOK (user must be a hash)') unless user.is_a?(Hash)
  goodbye('create_user_index() => NOK (user id is undefined)') unless user['id']

  id = user['id']
  login = user['login']
  name = user['name']

  unless @users_index[user['id']].nil?
    puts "create_user_index(space='#{space['name']}',id=#{id},login=#{login},name='#{name}' => OK (already exists)"
    return
  end

  user_index = {}

  FILES.each do |file|
    fname = file[:name]
    fields = file[:fields]
    user_index_name = {}
    fields.each do |field|
      user_index_name[field] = []
    end
    user_index[fname] = user_index_name
  end

  user_index['count'] = 0
  user_index['login'] = login
  user_index['name'] = name
  @users_index[id] = user_index
  puts "create_user_index(space='#{space['name']}',id=#{id},login=#{login},name='#{name}' => OK"

  user_index
end

space = get_space(ASSEMBLA_SPACE)
output_dirname = get_output_dirname(space, 'assembla')
csv_to_array("#{output_dirname}/users.csv").each do |row|
  @users << row
end

puts "#{ASSEMBLA_SPACE}: found #{@users.length} users"
@users.each do |user|
  create_user_index(user, space)
end

FILES.each do |file|
  fname = file[:name]
  pathname = "#{output_dirname}/#{fname}.csv"
  puts pathname
  csv_to_array(pathname).each do |h|
    file[:fields].each do |f|
      user_id = h[f]
      # Ignore empty user ids.
      next unless user_id && user_id.length.positive?
      user_index = @users_index[user_id]
      unless user_index
        @num_unknowns += 1
        h = {}
        h['id'] = user_id
        h['login'] = "unknown-#{@num_unknowns}"
        h['name'] = "Unknown ##{@num_unknowns}"
        user_index = create_user_index(h, space)
      end
      user_index['count'] += 1
      user_item = user_index[fname]
      user_item_field = user_item[f]
      user_item_field << h
    end
  end
end

pathname_report = "#{output_dirname}/report-users.csv"
CSV.open(pathname_report, 'wb') do |csv|
  @users_index.sort_by { |u| -u[1]['count'] }.each_with_index do |user_index, index|
    fields = FILES.map { |file| file[:fields].map { |field| "#{file[:name]}:#{field}" } }.flatten
    keys = %w[count id login name picture email organization phone] + fields
    csv << keys if index.zero?
    id = user_index[0]
    count = user_index[1]['count']
    login = user_index[1]['login']
    name = user_index[1]['name']
    picture = user_index[1]['picture']
    email = user_index[1]['email']
    organization = user_index[1]['organization']
    phone = user_index[1]['phone']
    row = [count, id, login, name, picture, email, organization, phone]
    fields.each do |f|
      f1, f2 = f.split(':')
      row << user_index[1][f1][f2].length
    end
    csv << row
    puts "#{count.to_s.rjust(4)} #{id} #{login}"
  end
end
puts pathname_report
