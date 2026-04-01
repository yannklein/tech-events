require 'sinatra'
require 'sinatra/json'
require 'sinatra/reloader'
require 'sinatra/activerecord'
require 'json'
require 'open-uri'
require 'rest-client'
require 'date'
require 'pry'
require 'nokogiri'
require 'httparty'
require 'watir'
require 'tzinfo'

require 'dotenv/load' if development?

# Meetup gems
require 'meetup_client'
# require_relative 'meetup_api'

# Gcal gems
require 'google/apis/calendar_v3'
require 'googleauth'
require 'googleauth/stores/file_token_store'
require 'fileutils'
require 'sinatra/cross_origin'

require_relative 'config/application'

require_relative 'services/api_fetcher'
require_relative 'services/openai_scraper'

configure do
  enable :cross_origin
end

before do
  response.headers['Access-Control-Allow-Origin'] = '*'
end

CALENDAR_ID = 'lewagon.org_i5sv5pnr5htimao32tkb9a4jko@group.calendar.google.com'.freeze
TIME_ZONE = 'Asia/Tokyo'.freeze

get '/api/groups' do
  groups = TkyEvenMeetup.all
  groups = groups.where(city: params[:city]) if params[:city]
  json groups
end

get '/api/events' do
  events = TkyEvenEvent.where('event_date >= ?', Date.today.prev_month(2)).order(event_date: :asc)
  events = events.joins(:tky_even_meetup).where(tky_even_meetup: { city: params[:city] }) if params[:city]
  json events
end

get '/api' do
  endpoints = {
    'endpoints': {
      "events": '/api/events?city=:city',
      "groups": '/api/groups?city=:city'
    }
  }
  json endpoints
end

get '/' do
  @groups = TkyEvenMeetup.all
  @events_per_city = TkyEvenEvent.order(created_at: :desc).group_by { |ev| ev.tky_even_meetup.city }
  p
  erb :index
end

get '/groups/new' do
  @platforms = %w[meetup doorkeeper eventbrite luma]
  @cities = %w[tokyo barcelona]
  erb :new
end

post '/groups' do
  TkyEvenMeetup.create(name: params[:name], platform: params[:platform], city: params[:city])
  redirect '/'
end

get '/fetch' do
  fetch_event
  erb :index
end

get '/auth' do
  "Code is #{params[:code]}"
end

options '*' do
  response.headers['Allow'] = 'GET, PUT, POST, DELETE, OPTIONS'
  response.headers['Access-Control-Allow-Headers'] = 'Authorization, Content-Type, Accept, X-User-Email, X-Auth-Token'
  response.headers['Access-Control-Allow-Origin'] = '*'
  200
end

def doorkeeper_api_fetch(group)
  url = "https://api.doorkeeper.jp/groups/#{group.name}/events"
  dk_token = 'UsV1JF8zkkTT5p2VSZz8'
  events_serialized = RestClient.get(url, { 'Autorization': "Bearer #{dk_token}" })
  events = JSON.parse(events_serialized)
  events.map do |event|
    location = event['event']['venue_name']
    {
      meetup_event_id: event['event']['id'].to_s,
      tky_even_meetup: TkyEvenMeetup.find_by(name: group.name),
      name: "@#{DateTime.parse(event['event']['starts_at']).new_offset('+09:00').strftime('%k:%M')} | #{event['event']['title']}",
      venue: location && location != '' ? location : 'Remote or no venue info',
      event_date: Date.parse(event['event']['starts_at']).strftime('%F'),
      url: event['event']['public_url'],
      description: "<p><a href='#{event['event']['public_url']}'>Open the event page</a></p>#{event['event']['description']}" || ''
    }
  end
rescue StandardError => e
  puts "  ⚠️ Fetching the above group (Doorkeeper) didn't work: #{e.class}: #{e.message}"
  []
end

def meetup_api_fetch(group)
  # Define the URL and the GraphQL query
  url = URI.parse('https://api.meetup.com/gql-ext')
  headers = {
    'Authorization' => "Bearer #{ENV['MEETUP_ACCESS_TOKEN']}",
    'Content-Type' => 'application/json'
  }

  # Define the GraphQL query
  query = {
    query: "query { groupByUrlname(urlname: \"#{group.name}\") { unifiedEvents(input: {first: 5}) { count pageInfo { endCursor } edges { node { id title eventUrl description dateTime timezone venue { name } } } } } }"
  }

  # Create a new HTTP request
  http = Net::HTTP.new(url.host, url.port)
  http.use_ssl = true

  # Set up the HTTP POST request
  request = Net::HTTP::Post.new(url.path, headers)
  request.body = query.to_json

  # Send the request and capture the response
  response = http.request(request)

  # Print the response body
  meetup_data = JSON.parse(response.body)

  # Check if response contains the events and return the list
  if meetup_data['data']['groupByUrlname']
    raw_events = meetup_data['data']['groupByUrlname']['unifiedEvents']['edges'].map { |edge| edge['node'] }
    raw_events.map do |raw_event|
      formatted_date = DateTime.parse(raw_event['dateTime']) rescue nil # rubocop:disable Style/RescueModifier
      {
        meetup_event_id: raw_event['id'],
        tky_even_meetup: group,
        name: "@#{formatted_date.strftime('%H:%M')} | #{raw_event['title']}",
        venue: raw_event['venue'].nil? ? 'Remote or no venue info' : raw_event['venue']['name'],
        event_date: formatted_date,
        url: raw_event['eventUrl'] || '',
        description: "<p><a href='#{raw_event['eventUrl']}'>Open the event page</a></p>#{raw_event['description'] || ''}"
      }
    end
  else
    puts "#{group.name} has no events or is invalid."
    []
  end
rescue StandardError => e
  puts "  ⚠️ Error fetching events for group #{group.name}: #{e.message}"
  []
end


# Gcal API post
OOB_URI = 'urn:ietf:wg:oauth:2.0:oob'.freeze
APPLICATION_NAME = 'Tokyo Tech Events'.freeze
CREDENTIALS_PATH = 'credentials.json'.freeze
# The file token.yaml stores the user's access and refresh tokens, and is
# created automatically when the authorization flow completes for the first
# time.
TOKEN_PATH = 'token.yaml'.freeze
SCOPE = 'https://www.googleapis.com/auth/calendar'

##
# Ensure valid credentials, either by restoring from the saved credentials
# files or intitiating an OAuth2 authorization. If authorization is required,
# the user's default browser will be launched to approve the request.
#
# @return [Google::Auth::UserRefreshCredentials] OAuth2 credentials
def authorize
  client_id = Google::Auth::ClientId.from_file CREDENTIALS_PATH
  token_store = Google::Auth::Stores::FileTokenStore.new file: TOKEN_PATH
  authorizer = Google::Auth::UserAuthorizer.new client_id, SCOPE, token_store
  user_id = 'default'
  credentials = authorizer.get_credentials user_id
  if credentials.nil?
    url = authorizer.get_authorization_url base_url: OOB_URI
    puts 'Open the following URL in the browser and enter the ' \
         'resulting code after authorization:\n' + url
    code = gets
    credentials = authorizer.get_and_store_credentials_from_code(
      user_id:, code:, base_url: OOB_URI
    )
  end
  credentials
end

def initialize_gcal
  # Initialize the API
  service = Google::Apis::CalendarV3::CalendarService.new
  service.client_options.application_name = APPLICATION_NAME
  service.authorization = authorize
  service
end

def fetch_existing_gcal_events_ids(service)
  ids = []
  response = service.list_events(CALENDAR_ID)
  puts 'Upcoming events:'
  puts 'No upcoming events found' if response.items.empty?
  response.items.each do |event|
    ids << event.id
  end
  ids
end

def post_to_gcalendar(events, service, existing_ids)
  # Create new events
  events.reject { |event| existing_ids.include?(event[:id]) }.each do |event|
    puts 'Event to be created:'
    p event[:name]
    gcal_event = Google::Apis::CalendarV3::Event.new(
      id: event[:id],
      summary: event[:name],
      location: event[:location],
      description: event[:description],
      html_link: event[:url],
      start: Google::Apis::CalendarV3::EventDateTime.new(
        date: event[:date], # should be like2020-03-25T17:04:00-07:00
        time_zone: TIME_ZONE
      ),
      end: Google::Apis::CalendarV3::EventDateTime.new(
        date: event[:date],
        time_zone: TIME_ZONE
      )
    )
    begin
      result = service.insert_event(CALENDAR_ID, gcal_event)
      puts "Event created: #{result.html_link}"
    rescue StandardError => e
      puts 'Event already exists'
      puts "Error: #{e.class}: #{e.message}"
    end
  end

  # Update existing ones
  events.select { |event| existing_ids.include?(event[:id]) }.each do |event|
    old_gcal_event = service.get_event(CALENDAR_ID, event[:id])
    puts 'Event to be modified:'
    p event
    gcal_event = Google::Apis::CalendarV3::Event.new(
      id: event[:id],
      summary: event[:name],
      location: event[:location],
      description: event[:description],
      html_link: event[:url],
      start: Google::Apis::CalendarV3::EventDateTime.new(
        date: event[:date], # should be like2020-03-25T17:04:00-07:00
        time_zone: TIME_ZONE
      ),
      end: Google::Apis::CalendarV3::EventDateTime.new(
        date: event[:date],
        time_zone: TIME_ZONE
      )
    )

    result = service.update_event(CALENDAR_ID, old_gcal_event.id, gcal_event)
    print "Event modified:#{result.updated}"
  end
end

# Code for rake
def fetch_event
  # ApiFetcher.new('meetup')
  #           .fetch_events(&method(:meetup_api_fetch))
  #           .store_events
  OpenaiScraper.new('meetup', 'https://www.meetup.com/')
              .fetch_events
              .store_events

  ApiFetcher.new('doorkeeper')
            .fetch_events(&method(:doorkeeper_api_fetch))
            .store_events

  OpenaiScraper.new('eventbrite', 'https://www.eventbrite.com/o/')
              .fetch_events
              .store_events

  OpenaiScraper.new('luma', 'https://lu.ma/')
              .fetch_events
              .store_events

  # Send them to Gcal
  # service = initialize_gcal
  # @existing_ids = fetch_existing_gcal_events_ids(service)
  # post_to_gcalendar(@events, service, @existing_ids)
end
